import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/firebase/firebase_providers.dart';
import '../domain/app_settings.dart';

/// `settings/app`, live. Read-only — see [AppSettings].
final appSettingsProvider = StreamProvider<AppSettings>((ref) {
  final db = ref.watch(firestoreProvider);
  return db.appSettingsDoc.snapshots().map(AppSettings.fromSnapshot);
}, retry: (_, _) => null);

/// The canned replies the composer's ⚡ sheet offers. Falls back to the same
/// defaults the backend ships with, so an unseeded `settings/app` still gives
/// staff something useful instead of an empty sheet.
final quickRepliesProvider = Provider<List<String>>((ref) {
  final settings = ref.watch(appSettingsProvider).value;
  final replies = settings?.quickReplies ?? const <String>[];
  if (replies.isNotEmpty) return replies;
  return const [
    'Ji, batayiye 🙏',
    'Rate DM me bhej raha hoon',
    'Stock available hai',
    'Ye design abhi out of stock hai',
    'Dispatch aaj ho jayega',
  ];
});

/// uid → name, for the "who replied" line on outgoing bubbles.
final staffNamesProvider = Provider<Map<String, String>>(
  (ref) => ref.watch(appSettingsProvider).value?.staffNames ?? const {},
);

/// phoneNumberId → label ("Reminders", "Inquiries"). Labels and the number
/// filter only appear once two or more business numbers are configured.
final numberLabelsProvider = Provider<Map<String, String>>(
  (ref) => ref.watch(appSettingsProvider).value?.numberLabels ?? const {},
);
