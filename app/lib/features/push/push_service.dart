import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/firebase/firebase_providers.dart';
import '../../firebase_options.dart';
import 'notification_channels.dart';
import 'push_providers.dart';

/// The background isolate handler.
///
/// FOUR RULES, all mandatory:
///   1. top-level or static — never a closure;
///   2. annotated `@pragma('vm:entry-point')` so tree-shaking cannot remove it;
///   3. it calls `Firebase.initializeApp()` itself, because this runs in a
///      FRESH ISOLATE with no access to any provider, singleton or `ref`;
///   4. it must finish inside 30 seconds or the OS kills the process.
///
/// It deliberately does almost nothing. The OS has already rendered the
/// notification from the payload's `notification` block — there is no work to
/// do here, and doing work would only make a cold start slower.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (kDebugMode) debugPrint('bg push ${message.messageId}');
}

/// How often the "I am looking at this chat" claim is refreshed while a chat is
/// open. The backend believes it for 120 seconds, so 45 leaves plenty of slack
/// for a missed tick.
const Duration kPresenceHeartbeat = Duration(seconds: 45);

/// Keeps at most this many devices per staff member. Four phones; ten is
/// generous headroom for reinstalls that have not aged out yet.
const int kMaxTokensPerStaff = 10;

class PushService {
  PushService(this._ref);

  final Ref _ref;

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  FirebaseFirestore get _db => _ref.read(firestoreProvider);
  String get _deviceId => _ref.read(deviceIdProvider);

  bool _wired = false;
  String? _token;
  Timer? _heartbeat;

  /// Mirrors the app lifecycle.
  ///
  /// The heartbeat must READ this rather than assume it is running because the
  /// screen is on. On Android the Dart isolate keeps ticking after the activity
  /// is paused, so a timer that hard-codes `foreground: true` re-asserts
  /// presence for a phone sitting in somebody's pocket — and the backend then
  /// skips every push for that chat, for as long as the process lives.
  bool _foreground = true;

  // -------------------------------------------------------------------------
  // Wiring
  // -------------------------------------------------------------------------

  /// Called once, from `main()`, BEFORE `runApp()` — `onBackgroundMessage` must
  /// be registered before the app starts or a push that arrives during startup
  /// has nowhere to go.
  static Future<void> registerBackgroundHandler() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  /// Called once the session is ready. Safe to call again.
  ///
  /// ⚠️ TWO LATCHES, NOT ONE, and the difference is a phone that never buzzes.
  ///
  /// `pushServiceProvider` is a plain `Provider` and is never disposed, so
  /// `_wired` survives sign-out. On a shared warehouse handset the SECOND staff
  /// member to sign in therefore arrived here with `_wired` already true and
  /// returned immediately — while `deregister()` had correctly stripped this
  /// device from the PREVIOUS user's `fcmTokens` on the way out. The new user's
  /// row never got a token, `_patchPresence` found no element to touch and wrote
  /// nothing, and the once-per-install `akn.askedForPush` flag meant the
  /// permission prompt never re-ran either. That phone received no notification
  /// for any customer until the process was killed and cold-started.
  ///
  /// Re-running the listener block instead would attach a SECOND `onMessage`
  /// subscription and show every foreground message twice. Hence: wiring is
  /// one-shot, token registration is per sign-in.
  Future<void> start() async {
    if (!_wired) {
      _wired = true;

      // `settings:` is a NAMED parameter since flutter_local_notifications 22 —
      // it was positional before, and the change is silent if you are not
      // watching the changelog.
      await localNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_notify'),
          iOS: DarwinInitializationSettings(
            // firebase_messaging asks for permission itself; asking twice shows
            // the staff member two dialogs for one thing.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final waId = response.payload;
          if (waId != null && waId.isNotEmpty) {
            _ref.read(pendingDeepLinkProvider.notifier).set(waId);
          }
        },
      );

      // A local notification that LAUNCHED the app does not fire
      // onDidReceiveNotificationResponse — the plugin surfaces it only here.
      // And getInitialMessage() cannot cover it either, because we built that
      // notification ourselves rather than letting FCM render it, so there is no
      // launch-intent extra for firebase_messaging to read. Without this, a
      // notification tapped after Android killed the app (routine on a 3 GB
      // handset) cold-started onto the chat list with no way to tell which
      // customer had been tapped.
      final launch = await localNotifications.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        final waId = launch.notificationResponse?.payload;
        if (waId != null && waId.isNotEmpty) {
          _ref.read(pendingDeepLinkProvider.notifier).set(waId);
        }
      }

      // iOS ONLY.
      //
      // On iOS the system presents the FCM alert itself from apns.payload.aps
      // while the app is foregrounded, and FLTFirebaseMessagingPlugin applies
      // these persisted options to anything without an original delegate —
      // including the local notification `_onForegroundMessage` used to post in
      // response. Asking for both put two identical banners and two "ding"s on
      // screen for one customer message. Android needs the local render instead
      // (see _onForegroundMessage), because there the FCM SDK SUPPRESSES the
      // tray notification while the activity is resumed.
      if (Platform.isIOS || Platform.isMacOS) {
        await _messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);

      // Returns null on a cold start that was NOT caused by a tap, so this must
      // always be null-checked.
      final initial = await _messaging.getInitialMessage();
      if (initial != null) _onOpened(initial);

      _messaging.onTokenRefresh.listen((token) {
        _token = token;
        unawaited(registerToken(token));
      });
    }

    // EVERY sign-in, not just the first.
    await refreshToken();
  }

  /// Ask for permission.
  ///
  /// NOT at first launch. iOS only ever shows this dialog ONCE per install, so
  /// burning it on a splash screen — before the staff member has any idea what
  /// the app is — is unrecoverable. The caller shows it after the chat list has
  /// rendered at least once.
  ///
  /// On Android 13+ this raises the POST_NOTIFICATIONS system dialog directly,
  /// which is why `permission_handler` is not a dependency of this project.
  Future<AuthorizationStatus> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    if (kDebugMode) {
      debugPrint('push auth: ${settings.authorizationStatus}');
    }
    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      await refreshToken();
    }
    return settings.authorizationStatus;
  }

  Future<void> refreshToken() async {
    final token = await _tokenSafely();
    if (token == null) return;
    _token = token;
    await registerToken(token);
  }

  /// iOS throws until the APNs token has landed.
  ///
  /// Since the Firebase iOS SDK 10.4.0, `getToken()` raises
  /// `[firebase_messaging/apns-token-not-set]` if it is called before APNs has
  /// answered. That is a race on every cold start, not an error — so retry,
  /// never crash. If it never resolves, the APNs key has not been uploaded to
  /// the Firebase console (see functions/lib/push.js for the matching log line
  /// on the server side).
  Future<String?> _tokenSafely() async {
    if (Platform.isIOS || Platform.isMacOS) {
      for (var i = 0; i < 10; i++) {
        final apns = await _messaging.getAPNSToken();
        if (apns != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    try {
      return await _messaging.getToken();
    } catch (e) {
      debugPrint('getToken failed: $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // The token array — which is also where presence lives
  // -------------------------------------------------------------------------

  /// Write this device's entry into `staff/{uid}.fcmTokens`.
  ///
  /// A TRANSACTION rather than `arrayUnion`/`arrayRemove`, and that is forced
  /// rather than chosen: array element operations require an EXACT DEEP MATCH
  /// of the element, and these maps change on every presence heartbeat. A
  /// read-modify-write is the only correct primitive.
  ///
  /// ⚠️ `FieldValue.serverTimestamp()` is ILLEGAL inside an array element, so
  /// `updatedAt` and `openAt` are client clocks. The backend only ever compares
  /// them against a freshness window, never against a server-written value.
  Future<void> registerToken(String token) async {
    final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
    if (uid == null) return;

    final deviceId = _deviceId;
    final openChat = _ref.read(openChatProvider);

    try {
      await _db.runTransaction((tx) async {
        final ref = _db.staffDoc(uid);
        final snap = await tx.get(ref);
        final raw = snap.data()?['fcmTokens'];
        final existing = raw is List ? raw : const [];

        final kept = <Map<String, dynamic>>[
          for (final item in existing)
            // Drop this device's previous entry AND any stale duplicate of the
            // same token that another device may have left behind.
            if (item is Map &&
                item['deviceId'] != deviceId &&
                item['token'] != token)
              Map<String, dynamic>.from(item),
        ];

        kept.add({
          'token': token,
          'deviceId': deviceId,
          'platform': Platform.isIOS ? 'ios' : 'android',
          'updatedAt': Timestamp.now(),
          'appState': 'foreground',
          'openChat': openChat,
          'openAt': openChat == null ? null : Timestamp.now(),
        });

        kept.sort((a, b) {
          final at = a['updatedAt'];
          final bt = b['updatedAt'];
          if (at is! Timestamp || bt is! Timestamp) return 0;
          return bt.compareTo(at); // newest first
        });

        tx.update(ref, {
          'fcmTokens': kept.take(kMaxTokensPerStaff).toList(),
        });
      });
    } catch (e) {
      // Never fatal. A missing token means no push, not a broken app.
      debugPrint('registerToken failed: $e');
    }
  }

  /// Remove this device from the roster.
  ///
  /// Called on sign-out, BEFORE `auth.signOut()`. Without it the phone keeps
  /// receiving the previous user's customer messages, which on a shared
  /// warehouse handset is a genuine confidentiality problem.
  Future<void> deregister() async {
    _heartbeat?.cancel();
    _heartbeat = null;

    final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
    final deviceId = _deviceId;
    // Dropped so a stale token cannot be patched into the NEXT user's presence
    // on this handset. `refreshToken()` from the next `start()` sets it again.
    _token = null;
    if (uid == null) return;

    try {
      await _db.runTransaction((tx) async {
        final ref = _db.staffDoc(uid);
        final snap = await tx.get(ref);
        final raw = snap.data()?['fcmTokens'];
        if (raw is! List) return;
        final kept = [
          for (final item in raw)
            if (item is Map && item['deviceId'] != deviceId)
              Map<String, dynamic>.from(item),
        ];
        tx.update(ref, {'fcmTokens': kept});
      });
    } catch (e) {
      debugPrint('deregister failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Presence
  // -------------------------------------------------------------------------

  /// "This device has this chat on screen."
  ///
  /// Written into our own token element, which is the only place the backend
  /// can read it AND the only field firestore.rules lets a staff phone write.
  /// That is what makes the whole skip-if-open rule work with no rules change.
  Future<void> setOpenChat(String? waId) async {
    _ref.read(openChatProvider.notifier).set(waId);
    _heartbeat?.cancel();
    _heartbeat = null;
    if (waId != null) {
      _heartbeat = Timer.periodic(kPresenceHeartbeat, (_) {
        // ⚠️ NEVER hard-code `foreground: true` here.
        //
        // ChatScreen.dispose() is the only thing that cancels this timer, and
        // pressing Home does not dispose the route. The lifecycle observer
        // correctly wrote `appState: 'background'` — and 45 seconds later this
        // timer overwrote it with 'foreground' and a fresh openAt, for as long
        // as the process lived. isWatchingThisChat then returned true for ever,
        // so the customer that staff member was actively negotiating with was
        // the one customer whose messages never buzzed.
        if (!_foreground) return;
        unawaited(_patchPresence(openChat: waId, foreground: true));
      });
    }
    await _patchPresence(openChat: waId, foreground: _foreground);
  }

  /// Give up the claim on [waId] — but only if it is still ours.
  ///
  /// A route swap BUILDS AND MOUNTS the incoming ChatScreen (which claims
  /// presence in its own initState) before the outgoing one is disposed at the
  /// end of the ~300 ms exit transition. An unconditional clear in dispose
  /// therefore wiped the presence of the chat the staff member is now actually
  /// looking at — and cancelled its heartbeat, which nothing restarts — so every
  /// message from the customer on screen buzzed the phone displaying them.
  Future<void> releaseOpenChat(String waId) async {
    if (_ref.read(openChatProvider) != waId) return;
    disposeHeartbeat();
    await setOpenChat(null);
  }

  /// Foreground / background, from the app lifecycle observer.
  Future<void> setForeground(bool foreground) async {
    _foreground = foreground;
    await _patchPresence(
      openChat: _ref.read(openChatProvider),
      foreground: foreground,
    );
  }

  Future<void> _patchPresence({
    required String? openChat,
    required bool foreground,
  }) async {
    final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
    final token = _token;
    if (uid == null || token == null) return;
    final deviceId = _deviceId;

    try {
      await _db.runTransaction((tx) async {
        final ref = _db.staffDoc(uid);
        final snap = await tx.get(ref);
        final raw = snap.data()?['fcmTokens'];
        if (raw is! List) return;

        var touched = false;
        final next = <Map<String, dynamic>>[];
        for (final item in raw) {
          if (item is! Map) continue;
          final entry = Map<String, dynamic>.from(item);
          if (entry['deviceId'] == deviceId) {
            entry['token'] = token;
            entry['appState'] = foreground ? 'foreground' : 'background';
            entry['openChat'] = openChat;
            entry['openAt'] = openChat == null ? null : Timestamp.now();
            entry['updatedAt'] = Timestamp.now();
            touched = true;
          }
          next.add(entry);
        }
        if (!touched) return; // registerToken has not run yet
        tx.update(ref, {'fcmTokens': next});
      });
    } catch (e) {
      // Presence is an optimisation. Losing it means an extra buzz, never a
      // missed message.
      debugPrint('presence patch failed: $e');
    }
  }

  void disposeHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  // -------------------------------------------------------------------------
  // Incoming
  // -------------------------------------------------------------------------

  /// Foreground.
  ///
  /// On Android the Firebase SDK SUPPRESSES the tray notification while the app
  /// is visible and delivers this instead, so we render it ourselves — which is
  /// also where per-chat grouping has to live, because FCM's
  /// `AndroidNotification` has a `tag` field but no `group` field.
  ///
  /// It never navigates. Yanking a staff member out of the chat they are typing
  /// in because a different customer wrote is exactly the wrong behaviour.
  Future<void> _onForegroundMessage(RemoteMessage message) async {
    // ANDROID ONLY. On Android the Firebase SDK suppresses the tray
    // notification while the activity is resumed, so this is the only way
    // anything shows at all. On iOS the system has ALREADY presented it from
    // apns.payload.aps — see setForegroundNotificationPresentationOptions in
    // start() — and rendering here put two banners and two sounds on screen for
    // one message. (It also means the open-chat guard below cannot help on iOS:
    // that decision is made natively before any Dart runs, which is exactly why
    // the real guard is server-side in functions/lib/push.js.)
    if (!Platform.isAndroid) return;

    final waId = message.data['waId'] as String?;
    if (waId == null || waId.isEmpty) return;

    // Belt and braces over the server-side skip: this closes the ~200 ms race
    // where somebody opens a chat at the exact moment a message for it lands.
    //
    // ⚠️ NOT for an escalation. If the bot has just decided this conversation
    // needs a person, the staff member staring at it is exactly the one who
    // must be told — suppressing it because the chat happens to be open is the
    // one case where the open-chat guard gives the wrong answer.
    if (message.data['type'] != 'attention' &&
        _ref.read(openChatProvider) == waId) {
      return;
    }

    final notification = message.notification;
    final title = notification?.title ?? 'Naya message';
    final body = notification?.body ?? '';

    // Phase 5. `data.type` is "chat" for an ordinary inbound message and
    // "attention" when handlers/botReply.js has decided a human is needed. Both
    // open the same chat; only the channel — and therefore the sound — differs.
    final isAttention = message.data['type'] == 'attention';
    final channel = isAttention ? kChatAttentionChannel : kChatChannel;

    final groupKey = 'chat_$waId';

    // ONE ENTRY PER CHAT, always the newest message — the same product decision
    // functions/lib/push.js makes with `tag` + `apns-collapse-id`.
    //
    // ⚠️ An Android notification's identity is (package, tag, id), so the id
    // must be CONSTANT per chat or the tag alone changes nothing. This used to
    // be `messageId.hashCode`: a different id per message, so eight photos from
    // one customer stacked into eight tray entries despite the shared tag —
    // precisely the "tray of sixty entries nobody reads" that buildChatPush
    // documents avoiding. 0 is deliberate: it is the id firebase-messaging
    // itself posts alongside the tag, so a foreground-rendered notification and
    // a background-rendered one for the same chat replace each other instead of
    // sitting side by side.
    const id = 0;

    await localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: isAttention ? Importance.max : Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_notify',
          // `tag` replaces the previous notification for this chat rather than
          // stacking — the same choice functions/lib/push.js makes for the
          // background case, so foreground and background look identical.
          tag: groupKey,
          groupKey: groupKey,
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: DarwinNotificationDetails(
          threadIdentifier: groupKey,
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: waId,
    );
  }

  /// Background or terminated, and the staff member tapped it.
  void _onOpened(RemoteMessage message) {
    final waId = message.data['waId'] as String?;
    if (waId == null || waId.isEmpty) return;
    _ref.read(pendingDeepLinkProvider.notifier).set(waId);
  }
}
