import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_providers.dart';

/// Signed in, but there is no `staff/{uid}` document.
///
/// firestore.rules requires that row for **every** read in the app, so without
/// this screen the staff member logs in successfully and then sees an empty
/// chat list, an empty settings page and no error anywhere — the single most
/// confusing state the app can be in, and the one nobody tests.
class NotStaffScreen extends ConsumerWidget {
  const NotStaffScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final email = ref.watch(sessionProvider).user?.email ?? '';

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.badge_outlined, size: 58, color: scheme.onSurfaceVariant),
                const SizedBox(height: 18),
                Text(
                  'Aapka account abhi set nahi hai',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Login to ho gaya, lekin AKN Chat ke staff list me aapka naam '
                  'nahi hai. Owner ko ye email bhejein — wo ek minute me add kar '
                  'denge.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (email.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      email,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  onPressed: () => ref.read(authActionsProvider).signOut(),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Sign out karein'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
