import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/widgets/states.dart';
import '../data/tally_actions.dart';
import '../domain/tally_models.dart';
import '../providers/tally_providers.dart';
import 'widgets/tally_widgets.dart';

/// **THE APPROVAL SCREEN.** About sixty seconds a week, and the reason the
/// whole feature is safe to run.
///
/// Why a tap exists at all, given that the owner asked for automation:
///
///   TALLY LAGS REALITY, AND IT LAGS IT IN THE DIRECTION THAT HURTS. Receipts
///   are entered in batches, often days late. Cheques in hand are not in Tally.
///   A UPI at 23:10 on Saturday is entered at 11:00 on Monday. The single most
///   likely failure of this feature is a dunning message to a customer who paid
///   last Thursday — and NO reconciliation check can catch that, because from
///   Tally's point of view the data is perfectly correct. Only a person who
///   knows what came in this week catches it.
///
///   The error is also asymmetric: an un-sent statement can go out an hour
///   later at zero cost; a sent one cannot be unsent.
///
///   And the owner holds facts that are in no database — who is mid-dispute,
///   whose son's wedding is this week, who was promised time on the phone
///   yesterday. That judgement is what makes a relationship business in Surat
///   work, and there is no field in Tally for it.
class RunReviewScreen extends ConsumerStatefulWidget {
  const RunReviewScreen({super.key, required this.runId});

  final String runId;

  @override
  ConsumerState<RunReviewScreen> createState() => _RunReviewScreenState();
}

class _RunReviewScreenState extends ConsumerState<RunReviewScreen> {
  final Set<String> _excluded = {};
  bool _warningsSeen = false;
  bool _checked = false;
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final runAsync = ref.watch(runProvider(widget.runId));
    final partiesAsync = ref.watch(runPartiesProvider(widget.runId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Outstanding'),
        actions: [
          if (runAsync.value?.needsApproval == true)
            TextButton(
              onPressed: _cancelRun,
              child: const Text('Cancel'),
            ),
        ],
      ),
      body: switch (runAsync) {
        AsyncValue(hasValue: false, hasError: true, :final error?) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(runProvider(widget.runId)),
          ),
        AsyncValue(hasValue: false) => const Center(child: CircularProgressIndicator()),
        AsyncValue(:final value?) => _Body(
            run: value,
            parties: partiesAsync.value ?? const [],
            excluded: _excluded,
            warningsSeen: _warningsSeen,
            checked: _checked,
            sending: _sending,
            onWarningsSeen: () => setState(() => _warningsSeen = true),
            onToggleParty: (guid, include) => setState(() {
              if (include) {
                _excluded.remove(guid);
              } else {
                _excluded.add(guid);
              }
            }),
            onChecked: (v) => setState(() => _checked = v),
            onApprove: _approve,
            runId: widget.runId,
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Future<void> _approve() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      final result = await ref.read(tallyActionsProvider).approveRun(
            runId: widget.runId,
            excludedPartyGuids: _excluded.toList(),
            acknowledgedWarnings: _warningsSeen,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('${result['approved'] ?? 0} statement bhejne ke liye laga diye.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancelRun() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ye batch cancel kar dein?'),
        content: const Text('Kisi ko kuch nahi jaayega. Agle Tuesday naya batch ban jaayega.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Rehne dijiye')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel kijiye')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(tallyActionsProvider).cancelRun(widget.runId);
      messenger.showSnackBar(const SnackBar(content: Text('Batch cancel ho gaya.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.run,
    required this.parties,
    required this.excluded,
    required this.warningsSeen,
    required this.checked,
    required this.sending,
    required this.onWarningsSeen,
    required this.onToggleParty,
    required this.onChecked,
    required this.onApprove,
    required this.runId,
  });

  final OutstandingRun run;
  final List<OutstandingParty> parties;
  final Set<String> excluded;
  final bool warningsSeen;
  final bool checked;
  final bool sending;
  final VoidCallback onWarningsSeen;
  final void Function(String guid, bool include) onToggleParty;
  final ValueChanged<bool> onChecked;
  final VoidCallback onApprove;
  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cost = ref.watch(runCostProvider(runId));
    final includable = parties.where((p) => p.isIncludable).toList();
    final willSend = includable.where((p) => !excluded.contains(p.partyGuid)).length;
    final blocked = parties.where((p) => !p.isIncludable && p.status != 'sent').toList();

    // The button unlocks only when: the run wants approval, the warnings have
    // been expanded at least once, the "maine sab check kar liya" box is
    // ticked, and there is somebody left to send to.
    final canApprove = run.needsApproval &&
        (run.warnings.isEmpty || warningsSeen) &&
        checked &&
        willSend > 0 &&
        !sending;

    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              _Header(run: run, cost: cost),
              if (run.staleReasonHi != null) _Alert(text: run.staleReasonHi!, colour: scheme.error),
              if (run.templateProblemHi != null) _Alert(text: run.templateProblemHi!, colour: scheme.error),
              if (run.abortReasonHi != null) _Alert(text: run.abortReasonHi!, colour: scheme.error),

              WarningBanner(warnings: run.warnings, onExpanded: onWarningsSeen),

              if (run.skipped.isNotEmpty)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: const Icon(Icons.block_outlined),
                    title: Text('${run.skipped.length} party chhod di gayi'),
                    subtitle: const Text('Kis ko, aur kyun'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      builder: (_) => _SkippedSheet(skipped: run.skipped),
                    ),
                  ),
                ),

              const Divider(height: 24),

              ...includable.map((p) => PartyTile(
                    party: p,
                    included: !excluded.contains(p.partyGuid),
                    onToggle: (v) => onToggleParty(p.partyGuid, v),
                    onTap: () => context.push(Routes.tallyParty(runId, p.partyGuid)),
                  )),

              ...parties.where((p) => p.status == 'sent').map((p) => PartyTile(
                    party: p,
                    included: true,
                    onToggle: (_) {},
                    onTap: () => context.push(Routes.tallyParty(runId, p.partyGuid)),
                  )),

              if (blocked.isNotEmpty) ...[
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'YE NAHI JAAYENGE',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: scheme.error,
                    ),
                  ),
                ),
                ...blocked.map((p) => PartyTile(
                      party: p,
                      included: false,
                      onToggle: (_) {},
                      onTap: () => context.push(Routes.tallyParty(runId, p.partyGuid)),
                    )),
              ],
              const SizedBox(height: 100),
            ],
          ),
        ),

        if (run.needsApproval)
          Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      value: checked,
                      onChanged: (v) => onChecked(v ?? false),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Maine sab check kar liya', style: TextStyle(fontSize: 14)),
                      subtitle: run.warnings.isNotEmpty && !warningsSeen
                          ? Text(
                              'Pehle upar wali warnings kholiye',
                              style: TextStyle(fontSize: 12, color: scheme.error),
                            )
                          : null,
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: canApprove ? onApprove : null,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: sending
                            ? const SizedBox(
                                height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('Bhej dijiye ($willSend)'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                run.statusHi +
                    (run.approvedByName != null ? '  ·  ${run.approvedByName} ne approve kiya' : ''),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.run, required this.cost});
  final OutstandingRun run;
  final RunCost cost;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'As on ${ddmmyyyy(run.asOnIso)}'
            '${run.builtAt != null ? '  ·  ${run.builtAt!.hour.toString().padLeft(2, '0')}:${run.builtAt!.minute.toString().padLeft(2, '0')} baje bana' : ''}',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            '${run.partyCount} party  ·  ${rupees(run.totalPaise)}',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Sabse purana ${run.oldestDebitAgeDays ?? '—'} din'
            '${run.thresholdDays != null ? '  ·  ${run.thresholdDays} din se upar wale' : ''}'
            '${run.ageingBasis == 'due_date' ? ' (due date se)' : ' (bill date se)'}',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            // Not because the number is large — it is about ₹3 — but because
            // the owner should never be surprised by a line on a bill.
            'Kharcha: ~₹${cost.inr.toStringAsFixed(0)}  '
            '(${cost.templates} template, ${cost.sessions} chat khula)',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Alert extends StatelessWidget {
  const _Alert({required this.text, required this.colour});
  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: colour.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: colour.withValues(alpha: 0.4)),
    ),
    child: Text(text, style: TextStyle(fontSize: 13, height: 1.35, color: colour)),
  );
}

/// "Kis-kis ko nahi bheja, aur kyun" for THIS run. Not an afterthought: for a
/// money problem it shows both figures, because that is what settles a
/// question with the accountant.
class _SkippedSheet extends StatelessWidget {
  const _SkippedSheet({required this.skipped});
  final List<SkippedParty> skipped;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (_, controller) => ListView(
        controller: controller,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Kis-kis ko nahi bheja, aur kyun',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
          ...skipped.map((s) => ListTile(
                title: Text(s.partyName, style: const TextStyle(fontSize: 14.5)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.skipReasonHi, style: const TextStyle(fontSize: 12.5, height: 1.3)),
                    if (s.isMoneyProblem &&
                        s.billsSumPaise != null &&
                        s.ledgerClosingPaise != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Bill-wise ${rupees(-s.billsSumPaise!)}  vs  ledger ${rupees(-s.ledgerClosingPaise!)}'
                        '${s.reconcileDiffPaise != null ? '  (farak ${rupees(-s.reconcileDiffPaise!)})' : ''}',
                        style: TextStyle(fontSize: 11.5, color: scheme.error),
                      ),
                    ],
                    if (s.mobileCandidates.length > 1) ...[
                      const SizedBox(height: 4),
                      Text(
                        s.mobileCandidates.map((c) => '+$c').join('   '),
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
                trailing: s.duePaise != null
                    ? Text(rupees(s.duePaise!), style: const TextStyle(fontSize: 12.5))
                    : null,
                isThreeLine: true,
              )),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
