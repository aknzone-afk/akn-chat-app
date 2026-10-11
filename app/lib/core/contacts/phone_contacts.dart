import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 11-Oct-2026 (owner): the chat header shows the name this number is saved
/// under in THIS phone's contacts. Read once per app start, read-only; keyed
/// by the last 10 digits so "+91 98…", "098…" and "98…" all match.
final phoneContactNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  try {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted && status != PermissionStatus.limited) {
      return const {};
    }
    final all = await FlutterContacts.getAll(
      properties: {ContactProperty.name, ContactProperty.phone},
    );
    final out = <String, String>{};
    for (final c in all) {
      final name = c.displayName?.trim();
      if (name == null || name.isEmpty) continue;
      for (final p in c.phones) {
        final k = last10(p.normalizedNumber ?? p.number);
        if (k != null) out.putIfAbsent(k, () => name);
      }
    }
    return out;
  } catch (_) {
    return const {};
  }
});

String? last10(String? raw) {
  final d = (raw ?? '').replaceAll(RegExp(r'\D'), '');
  return d.length >= 10 ? d.substring(d.length - 10) : null;
}
