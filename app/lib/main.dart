import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/media/media_cache.dart';
import 'core/prefs/prefs.dart';
import 'features/chat/presentation/media/attach_sheet.dart';
import 'features/push/notification_channels.dart';
import 'features/push/push_service.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Local test lab only (shop PC, 8-Oct-2026): `--dart-define=USE_EMULATORS=true`
  // points the app at the Firebase emulators on the PC (10.0.2.2 from the
  // Android emulator). OFF in every real build — the constant defaults false.
  if (const bool.fromEnvironment('USE_EMULATORS')) {
    const host = String.fromEnvironment('EMULATOR_HOST', defaultValue: '10.0.2.2');
    await FirebaseAuth.instance.useAuthEmulator(host, 9099);
    FirebaseFirestore.instance.useFirestoreEmulator(host, 8080);
    await FirebaseStorage.instance.useStorageEmulator(host, 9199);
    FirebaseFunctions.instanceFor(region: 'asia-south1').useFunctionsEmulator(host, 5001);
  }

  // MUST be set before ANY other Firestore call, exactly once.
  //
  // Offline persistence is already ON by default on iOS and Android; this is
  // documentation plus a deliberate cache size. The `persistenceEnabled`
  // deprecation people remember is in the native/JS SDKs
  // (`setLocalCacheSettings`) and has not been surfaced in FlutterFire, whose
  // `Settings` class still has no `localCache` and carries no `@Deprecated`.
  //
  // 200 MB, not CACHE_SIZE_UNLIMITED: the 40 MB default is too small for a busy
  // chat once Phase 4 caches media, and unlimited disables LRU garbage
  // collection entirely on what are low-storage staff phones.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: 200 * 1024 * 1024,
  );

  // Auto-indexes the local cache so paged history queries do not full-scan it.
  //
  // Fire and forget, but never unguarded: if the platform channel rejects it
  // (unsupported platform, plugin timing) an unawaited rejection is reported
  // through PlatformDispatcher.onError during startup and gets blamed on
  // whatever ran next. A missing cache index is a slow query, not an outage.
  final indexManager = FirebaseFirestore.instance.persistentCacheIndexManager();
  if (indexManager != null) {
    unawaited(indexManager.enableIndexAutoCreation().catchError((Object _) {}));
  }

  // MUST be registered before runApp(): a push arriving while the app is
  // starting has nowhere to go otherwise.
  await PushService.registerBackgroundHandler();

  // Create the Android notification channels EAGERLY, before any message can
  // arrive. If the FCM SDK creates the first channel while the app is in the
  // background, Android suppresses that notification and will not prompt for
  // POST_NOTIFICATIONS until the app is next opened — and those notifications
  // are lost. See features/push/notification_channels.dart.
  await createNotificationChannels();

  // Makes the Android system Photo Picker the gallery on every version, not
  // just 13+, and is what makes `limit:` take effect. It also has to happen
  // before ANY pick call. Going through the Photo Picker is what lets the
  // manifest declare zero storage permissions.
  enableAndroidPhotoPicker();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Delete media the staff member has not touched in a month, then trim to
  // 400 MB. Unawaited: staff phones are low-storage, but nobody should wait for
  // a directory walk to see their chats.
  unawaited(MediaCache.sweep());

  final prefs = await SharedPreferences.getInstance();

  // 11-Oct-2026: pick up the staff mark (storage.rules) without waiting an hour.
  unawaited(FirebaseAuth.instance.currentUser?.getIdToken(true).catchError((_) => null) ?? Future<void>.value());

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const AknChatApp(),
    ),
  );
}
