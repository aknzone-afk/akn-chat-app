import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/formatters.dart';
import '../../../core/widgets/states.dart';
import '../data/tally_actions.dart';
import '../domain/tally_models.dart';
import '../providers/tally_providers.dart';
import 'widgets/tally_widgets.dart';

/// One party, in full: every bill with BOTH ageing columns, the two
/// reconciliation figures, the exact caption and template parameters that will
/// be sent, and the phone number unmasked.
///
/// Reviewing a statement you cannot see is not reviewing it.
class PartyDetailScreen extends ConsumerWidget {
  const PartyDetailScreen({super.key, required this.runId, required this.partyGuid});

  final String runId;
  final String partyGuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(runPartyProvider((runId: runId, partyGuid: partyGuid)));

    return Scaffold(
      appBar: AppBar(title: const Text('Party')),
      body: switch (async) {
        AsyncValue(hasValue: false, hasError: true, :final error?) => ErrorView(error: error),
        AsyncValue(hasValue: false) => const Center(child: CircularProgressIndicator()),
        AsyncValue(:final value?) => _Body(runId: runId, party: value),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.runId, required this.party});

  final String runId;
  final OutstandingParty party;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(party.partyName,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                rupees(party.duePaise),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${party.billCount} bill  ·  sabse purana ${party.oldestDebitAgeDays ?? '—'} din '
                '(${party.oldestDebitOverdueDays ?? '—'} din overdue)',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),

        // ⚠️ FULL, UNMASKED. Staff must be able to verify the number by eye
        // against what they know — masking it defeats the review.
        ListTile(
          leading: const Icon(Icons.phone_outlined),
          title: Text(party.waId != null ? prettyPhone(party.waId!) : 'Number nahi hai'),
          subtitle: Text(
            '${MobileVerdict.hi(party.mobileVerdict)}'
            '${party.mobileSource == 'override' ? ' (haath se set kiya)' : ''}',
          ),
        ),

        if (party.nameMismatchWarning)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Chat me is number ka naam Tally ke naam se kaafi alag hai. Aksar ye theek hi hota '
              'hai (staff "Rajubhai" likh dete hain) — bas ek nazar daal lijiye.',
              style: TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),

        ReconcileRow(
          billsSumPaise: party.billsSumPaise,
          ledgerClosingPaise: party.ledgerClosingPaise,
          diffPaise: party.reconcileDiffPaise,
        ),

        const _SectionLabel('BILL-WISE HISAAB'),
        AgeingTable(bills: party.bills),

        const _SectionLabel('JO MESSAGE JAAYEGA'),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(party.caption ?? '—', style: const TextStyle(fontSize: 13.5, height: 1.45)),
              if (party.fileName != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(party.fileName!, style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        if (party.templateParams.isNotEmpty) ...[
          const _SectionLabel('AGAR CHAT BAND HAI (TEMPLATE)'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Namaste ${_p(party, 0)} ji,\n'
              'Aapka AKN ZONE ka outstanding ₹${_p(party, 1)} hai. '
              'Sabse purana bill ${_p(party, 2)} din ka hai.\n'
              'Poora bill-wise hisaab attached statement me hai.\n'
              'Payment ho chuka ho to is message ko ignore kijiye.',
              style: const TextStyle(fontSize: 13.5, height: 1.45),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              // The ₹ is FIXED TEXT inside the approved template, not part of
              // the parameter. If our formatting ever breaks, the fixed text is
              // a stable anchor and the failure is visible rather than silent.
              'Parameters: ${party.templateParams.join("  |  ")}',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],

        if (party.pdfPath != null) ...[
          const _SectionLabel('STATEMENT PDF'),
          _PdfTile(pdfPath: party.pdfPath!, sha256: party.pdfSha256),
        ],

        const SizedBox(height: 16),
        if (party.isIncludable)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Is batch se hata dijiye'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ref.read(tallyActionsProvider).excludeParty(
                        runId: runId,
                        partyGuid: party.partyGuid,
                      );
                  messenger.showSnackBar(const SnackBar(content: Text('Hata diya.')));
                } catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('$e')));
                }
              },
            ),
          ),

        if (party.status == 'sent')
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Bheja gaya${party.sentAt != null ? ' — ${party.sentAt}' : ''}'
              '${party.channel != null ? ' (${party.channel})' : ''}'
              '${party.fellBackToTemplate ? ' · chat band tha, template lagana pada' : ''}',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),

        if (party.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(party.error!, style: TextStyle(fontSize: 12.5, color: scheme.error)),
          ),

        const SizedBox(height: 32),
      ],
    );
  }

  static String _p(OutstandingParty party, int i) =>
      i < party.templateParams.length ? party.templateParams[i] : '—';
}

class _PdfTile extends StatelessWidget {
  const _PdfTile({required this.pdfPath, this.sha256});
  final String pdfPath;
  final String? sha256;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: FirebaseStorage.instance.ref(pdfPath).getDownloadURL(),
    builder: (context, snap) => ListTile(
      leading: const Icon(Icons.picture_as_pdf_outlined),
      title: const Text('Statement kholiye'),
      subtitle: Text(
        sha256 != null ? 'sha256 ${sha256!.substring(0, 12)}…' : pdfPath,
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: snap.hasData ? const Icon(Icons.open_in_new, size: 18) : null,
      onTap: snap.hasData
          ? () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Statement ka link'),
                  content: SelectableText(snap.data!, style: const TextStyle(fontSize: 12)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Theek hai')),
                  ],
                ),
              )
          : null,
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
