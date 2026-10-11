import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/prefs/prefs.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/push/push_providers.dart';
import 'router.dart';
import 'theme.dart';

class AknChatApp extends ConsumerStatefulWidget {
  const AknChatApp({super.key});

  @override
  ConsumerState<AknChatApp> createState() => _AknChatAppState();
}

class _AknChatAppState extends ConsumerState<AknChatApp>
    with WidgetsBindingObserver {
  bool _pushStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // "This phone was alive at …". One of exactly two fields firestore.rules
    // lets a staff member write on their own roster row.
    if (state == AppLifecycleState.resumed) {
      ref.read(authActionsProvider).touchLastSeen();
    }

    // The other half of the push presence rule. The backend skips a push only
    // for a device that has that chat open AND is in the foreground, so going
    // to the background has to be reported — otherwise a staff member stops
    // being notified for whichever chat they last had on screen.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        ref
            .read(pushServiceProvider)
            .setForeground(state == AppLifecycleState.resumed),
      );
    }
  }

  void _consumePendingLink() {
    final waId = ref.read(pendingDeepLinkProvider);
    if (waId == null) return;
    if (ref.read(sessionProvider).status != SessionStatus.ready) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(routerProvider).go(Routes.chat(waId));
      ref.read(pendingDeepLinkProvider.notifier).clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep the session alive for the whole app lifetime, so the router's guard
    // never sees it torn down and re-initialised.
    final session = ref.watch(sessionProvider);

    // Start push only once we know who is signed in: the token has to be
    // written onto THIS staff member's row, and `staff/{uid}` is readable only
    // by its owner.
    if (session.status == SessionStatus.ready && !_pushStarted) {
      _pushStarted = true;
      unawaited(ref.read(pushServiceProvider).start());
    }
    if (session.status == SessionStatus.signedOut) {
      _pushStarted = false;
    }

    // A tapped notification, consumed exactly once.
    ref.listen<String?>(pendingDeepLinkProvider, (_, _) => _consumePendingLink());

    // …and re-evaluated when the session flips, for the cold-start case: a push
    // tapped from a terminated app sets the link while auth is still loading,
    // so the listener above declines it once and this picks it up after the
    // login round trip. Held rather than dropped — tapping a customer's message
    // and landing on the chat list is the failure this prevents.
    ref.listen<Session>(sessionProvider, (_, next) {
      if (next.status == SessionStatus.ready) _consumePendingLink();
    });

    return MaterialApp.router(
      title: 'AKN Chat',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),
      theme: aknLightTheme,
      darkTheme: aknDarkTheme,
      themeMode: ref.watch(themeModeProvider),
    );
  }
}
