import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/not_staff_screen.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/bot/presentation/bot_activity_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/chats/presentation/chat_list_screen.dart';
import '../features/settings/presentation/persona_editor_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/tally/presentation/party_detail_screen.dart';
import '../features/tally/presentation/run_review_screen.dart';
import '../features/tally/presentation/sent_log_screen.dart';
import '../features/tally/presentation/skipped_screen.dart';
import '../features/tally/presentation/tally_screen.dart';
import 'theme.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const notStaff = '/not-staff';
  static const chats = '/chats';
  static const settings = '/settings';

  /// Phase 5.
  static const persona = '/settings/persona';
  static const botActivity = '/settings/bot-activity';

  /// Phase 6 — the Tally bridge.
  static const tally = '/tally';
  static const tallySkipped = '/tally/skipped';
  static const tallySent = '/tally/sent';

  static String chat(String waId) => '$chats/$waId';

  static String tallyRun(String runId) => '$tally/run/$runId';
  static String tallyParty(String runId, String partyGuid) =>
      '$tally/run/$runId/party/$partyGuid';
}

final routerProvider = Provider<GoRouter>((ref) {
  // `refreshListenable` is what makes the guard reactive. Rebuilding the whole
  // GoRouter from a `ref.watch` would work too — and would reset the entire
  // navigation stack on every auth tick, throwing staff out of the chat they
  // are reading the moment a token refreshes.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(sessionProvider, (_, _) => refresh.value++);

  return GoRouter(
    initialLocation: Routes.chats,
    refreshListenable: refresh,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;

      switch (session.status) {
        case SessionStatus.loading:
          return loc == Routes.splash ? null : Routes.splash;

        case SessionStatus.signedOut:
          if (loc == Routes.login) return null;
          // Keep the deep link so we can land on it after signing in.
          final from = Uri.encodeComponent(state.uri.toString());
          return '${Routes.login}?from=$from';

        case SessionStatus.notStaff:
          return loc == Routes.notStaff ? null : Routes.notStaff;

        case SessionStatus.ready:
          if (loc == Routes.login ||
              loc == Routes.splash ||
              loc == Routes.notStaff) {
            final from = state.uri.queryParameters['from'];
            if (from != null && from.isNotEmpty) {
              final decoded = Uri.decodeComponent(from);
              // Never bounce back into an auth route — that blows
              // `redirectLimit` and lands staff on go_router's error screen.
              if (!decoded.startsWith(Routes.login) &&
                  !decoded.startsWith(Routes.splash) &&
                  !decoded.startsWith(Routes.notStaff)) {
                return decoded;
              }
            }
            return Routes.chats;
          }
          return null;
      }
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.notStaff, builder: (_, _) => const NotStaffScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      GoRoute(
        path: Routes.persona,
        builder: (_, _) => const PersonaEditorScreen(),
      ),
      GoRoute(
        path: Routes.botActivity,
        builder: (_, _) => const BotActivityScreen(),
      ),

      // Phase 6. `/tally/skipped` and `/tally/sent` are declared BEFORE the
      // `run/:runId` subtree so neither can ever be swallowed by a path
      // parameter.
      GoRoute(
        path: Routes.tally,
        builder: (_, _) => const TallyScreen(),
        routes: [
          GoRoute(path: 'skipped', builder: (_, _) => const SkippedScreen()),
          GoRoute(path: 'sent', builder: (_, _) => const SentLogScreen()),
          GoRoute(
            path: 'run/:runId',
            builder: (context, state) =>
                RunReviewScreen(runId: state.pathParameters['runId']!),
            routes: [
              GoRoute(
                path: 'party/:partyGuid',
                builder: (context, state) => PartyDetailScreen(
                  runId: state.pathParameters['runId']!,
                  partyGuid: state.pathParameters['partyGuid']!,
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.chats,
        builder: (_, _) => const ChatListScreen(),
        routes: [
          GoRoute(
            path: ':waId',
            name: 'chat',
            builder: (context, state) =>
                ChatScreen(waId: state.pathParameters['waId']!),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore_off_outlined, size: 44),
              const SizedBox(height: 12),
              const Text('Ye screen nahi mili.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(Routes.chats),
                child: const Text('Chats par jaayein'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
});

/// Shown for the fraction of a second before Firebase Auth reports in. Branded
/// rather than a bare spinner, because on a cold start on a slow phone this is
/// the first thing staff see.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AknColors.maroonLight, AknColors.maroonDark],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.center,
              child: const Text(
                'AKN',
                style: TextStyle(
                  color: AknColors.goldSoft,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 90,
              child: LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
