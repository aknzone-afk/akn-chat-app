import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/formatters.dart';
import '../../../core/widgets/states.dart';
import '../providers/tally_providers.dart';
import 'widgets/tally_widgets.dart';

/// "Kya-kya bheja gaya."
///
/// Reads `tally_sends`, which is the idempotency ledger AND the dispute record:
/// what we said, to whom, when, and for how much. It is kept for 400 days,
/// because "you sent me a statement saying ₹1,25,000 in July" is a
/// conversation that happens in December.
class SentLogScreen extends ConsumerWidget {
  const SentLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(recentSendsProvider);
    final counters = ref.watch(tallyCountersTodayProvider).value ?? const {};

    return Scaffold(
      appBar: AppBar(title: const Text('Kya-kya bheja gaya')),
      body: switch (async) {
        AsyncValue(hasValue: false, hasError: true, :final error?) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(recentSendsProvider),
          ),
        AsyncValue(hasValue: false) => const Center(child: CircularProgressIndicator()),
        AsyncValue(:final value?) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Text(
                  'Aaj: ${counters['total'] ?? 0} message  ·  '
                  '${counters['statements'] ?? 0} statement, '
                  '${counters['bills'] ?? 0} bill, '
                  '${counters['biltys'] ?? 0} bilty',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (value.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Abhi tak kuch nahi bheja gaya.', textAlign: TextAlign.center),
                ),
              ...value.map((s) => _SendTile(send: s)),
              const SizedBox(height: 32),
            ],
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _SendTile extends StatelessWidget {
  const _SendTile({required this.send});
  final TallySend send;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (icon, colour) = switch (send.status) {
      'SENT' => (Icons.done_all, Colors.green.shade600),
      'DEAD' => (Icons.error_outline, scheme.error),
      'SKIPPED' => (Icons.remove_circle_outline, scheme.onSurfaceVariant),
      _ => (Icons.schedule, scheme.onSurfaceVariant),
    };

    final kindHi = switch (send.kind) {
      'statement' => 'Outstanding statement',
      'bill' => 'Bill',
      'bilty' => 'Bilty / LR',
      _ => send.kind,
    };

    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: colour),
      title: Text(
        '$kindHi${send.amountPaise != null ? '  ·  ${rupees(send.amountPaise!)}' : ''}',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${send.waId != null ? prettyPhone(send.waId!) : '—'}'
            '${send.channel != null ? '  ·  ${send.channel == 'template' ? 'template' : 'chat'}' : ''}'
            '${send.fellBackToTemplate ? '  ·  chat band tha' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          if (send.error != null)
            Text(
              send.error!,
              style: TextStyle(fontSize: 11.5, color: scheme.error),
            ),
        ],
      ),
      trailing: send.sentAt != null
          ? Text(chatListTime(send.sentAt!), style: const TextStyle(fontSize: 11.5))
          : null,
    );
  }
}
