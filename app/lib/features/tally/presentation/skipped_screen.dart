import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/formatters.dart';
import '../../../core/widgets/states.dart';
import '../data/tally_actions.dart';
import '../domain/tally_models.dart';
import '../providers/tally_providers.dart';

/// "Kis-kis ko nahi bheja, aur kyun."
///
/// This is **not an afterthought screen** — it is where the ledger-to-mobile
/// mapping work actually gets done, and that mapping is where the project
/// lives or dies. Every party is grouped by verdict, with a Hinglish
/// explanation and the fix inline: choose a number, type a number, block the
/// party, or whitelist it.
///
/// One tap, once, per party, forever. An override is keyed on the ledger GUID,
/// so it survives a rename in Tally.
class SkippedScreen extends ConsumerWidget {
  const SkippedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(problemPartiesProvider);
    final grouped = ref.watch(problemsByVerdictProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Kis-kis ko nahi bheja')),
      body: switch (async) {
        AsyncValue(hasValue: false, hasError: true, :final error?) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(problemPartiesProvider),
          ),
        AsyncValue(hasValue: false) => const Center(child: CircularProgressIndicator()),
        AsyncValue(:final value?) when value.isEmpty => const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Sab party ke number theek hain 👍',
                style: TextStyle(fontSize: 15),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        _ => ListView(
            children: [
              // Ordered so the ones a human can actually fix come first —
              // "choose between these two numbers" is thirty seconds of work,
              // "this number belongs to us" needs nothing done at all.
              for (final verdict in const [
                'AMBIGUOUS_MULTIPLE',
                'MISSING',
                'MALFORMED',
                'DUPLICATE_NUMBER',
                'NO_CHAT_YET',
                'FOREIGN',
                'BLOCKED',
                'SELF',
              ])
                if ((grouped[verdict] ?? const []).isNotEmpty)
                  _VerdictGroup(verdict: verdict, parties: grouped[verdict]!),
              const SizedBox(height: 32),
            ],
          ),
      },
    );
  }
}

class _VerdictGroup extends StatelessWidget {
  const _VerdictGroup({required this.verdict, required this.parties});

  final String verdict;
  final List<TallyParty> parties;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            '${MobileVerdict.hi(verdict)}  (${parties.length})',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        ),
        if (MobileVerdict.fixHi(verdict).isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              MobileVerdict.fixHi(verdict),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ...parties.map((p) => _PartyRow(party: p)),
      ],
    );
  }
}

class _PartyRow extends ConsumerWidget {
  const _PartyRow({required this.party});
  final TallyParty party;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(party.ledgerName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),

            // Verbatim, so staff can read a number a regex could not. Very
            // often a human can see straight away what was meant.
            if ((party.mobileRaw ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Tally me likha hai:  "${party.mobileRaw}"',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ],

            if (party.duplicateWith.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Yehi number in par bhi hai: ${party.duplicateWith.join(", ")}',
                style: TextStyle(fontSize: 12.5, color: scheme.error, height: 1.3),
              ),
            ],

            const SizedBox(height: 8),

            // The one-tap fix for an ambiguity: BOTH numbers, tap to choose.
            // We never pick the first one — for a message about money that is
            // a coin flip between two real people.
            if (party.mobileCandidates.length > 1)
              Wrap(
                spacing: 8,
                children: party.mobileCandidates
                    .map((c) => ActionChip(
                          label: Text(prettyPhone(c)),
                          onPressed: () => _setMobile(context, ref, c),
                        ))
                    .toList(),
              ),

            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Number daaliye'),
                  onPressed: () => _typeMobile(context, ref),
                ),
                if (party.mobileVerdict == 'NO_CHAT_YET' && party.waId != null)
                  TextButton.icon(
                    icon: const Icon(Icons.verified_user_outlined, size: 18),
                    label: const Text('Whitelist'),
                    onPressed: () => _run(
                      context,
                      () => ref.read(tallyActionsProvider).whitelistParty(party.waId!),
                      'Whitelist kar diya.',
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => _run(
                    context,
                    () => ref.read(tallyActionsProvider).setDoNotSend(
                          ledgerGuid: party.ledgerGuid,
                          doNotSend: !party.doNotSend,
                        ),
                    party.doNotSend ? 'Dobara chalu kar diya.' : 'Band kar diya.',
                  ),
                  child: Text(
                    party.doNotSend ? 'Dobara chalu' : 'Kabhi mat bhejo',
                    style: TextStyle(color: party.doNotSend ? null : scheme.error),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _typeMobile(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(party.ledgerName, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((party.mobileRaw ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Tally me likha hai: "${party.mobileRaw}"',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '10 digit mobile',
                hintText: '9825012345',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Ye number Tally ke ledger par nahi, yahan set hoga — aur Tally me naam badalne '
              'par bhi bana rahega.',
              style: TextStyle(fontSize: 11.5, height: 1.3),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Rehne dijiye')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Set kijiye'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty || !context.mounted) return;
    await _setMobile(context, ref, value);
  }

  Future<void> _setMobile(BuildContext context, WidgetRef ref, String mobile) => _run(
    context,
    () => ref.read(tallyActionsProvider).setPartyMobile(
          ledgerGuid: party.ledgerGuid,
          mobile: mobile,
          reason: 'app se set kiya',
        ),
    'Number set ho gaya.',
  );

  static Future<void> _run(BuildContext context, Future<void> Function() op, String ok) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op();
      messenger.showSnackBar(SnackBar(content: Text(ok)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
