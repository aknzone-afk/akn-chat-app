import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/format/formatters.dart';
import '../../domain/tally_models.dart';
import '../../providers/tally_providers.dart';

/// Rupees from integer paise. **The app never does money arithmetic** — every
/// figure here was computed on the bridge, re-checked on the server, and is
/// only being displayed. `formatInr` matches `money.format()` in the bridge.
String rupees(int paise) => formatInr(paise / 100);

/// "01-05-2026" from "2026-05-01" — the only date format a customer, or the
/// owner, ever sees in this feature.
String ddmmyyyy(String? iso) {
  if (iso == null || iso.length < 10) return '—';
  return '${iso.substring(8, 10)}-${iso.substring(5, 7)}-${iso.substring(0, 4)}';
}

// ---------------------------------------------------------------------------
// The bridge health banner — the highest-value thing in this feature
// ---------------------------------------------------------------------------

/// Shown on the CHAT LIST, not buried in Settings.
///
/// Logs on a shop PC are write-only media. This is the thing that actually
/// makes "broken for three days" visible, and it costs one document read.
class BridgeAlertBanner extends ConsumerWidget {
  const BridgeAlertBanner({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alert = ref.watch(bridgeAlertProvider);
    if (alert == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  alert,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class BridgeHealthCard extends ConsumerWidget {
  const BridgeHealthCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(bridgeStatusProvider).value;
    final control = ref.watch(bridgeControlProvider).value;
    final scheme = Theme.of(context).colorScheme;

    final dead = status?.looksDead ?? true;
    final unhealthy = status?.isUnhealthy ?? false;
    final colour = dead || unhealthy ? scheme.error : Colors.green.shade600;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Text(
                  'Shop computer',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (control?.killSwitch == true)
                  const _Chip(text: 'BAND HAI', colour: Colors.red)
                else if (control?.dryRun == true)
                  const _Chip(text: 'DRY RUN', colour: Colors.orange)
                else if (control?.rehearsalTo != null)
                  const _Chip(text: 'REHEARSAL', colour: Colors.orange),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              status == null
                  ? 'Abhi tak koi khabar nahi aayi.'
                  : dead
                      ? (ref.watch(bridgeAlertProvider) ?? 'Sync nahi ho raha.')
                      : 'Sab theek hai — aakhri sync ${_ago(status.lastSeen)}.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.35),
            ),
            if (status?.lastErrorHi != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status!.lastErrorHi!,
                      style: TextStyle(fontSize: 12.5, color: scheme.onErrorContainer, height: 1.35),
                    ),
                    if (status.lastErrorAssertion != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Code: ${status.lastErrorAssertion}',
                        style: TextStyle(fontSize: 11, color: scheme.onErrorContainer.withValues(alpha: 0.75)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (status?.companyName != null) ...[
              const SizedBox(height: 8),
              Text(
                'Company: ${status!.companyName}'
                '${status.partyCount != null ? '  ·  ${status.partyCount} party' : ''}'
                '${status.bridgeVersion != null ? '  ·  v${status.bridgeVersion}' : ''}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime? when) {
    if (when == null) return 'kabhi nahi';
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 2) return 'abhi';
    if (d.inHours < 1) return '${d.inMinutes} minute pehle';
    if (d.inDays < 1) return '${d.inHours} ghante pehle';
    return '${d.inDays} din pehle';
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.colour});
  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: colour.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: colour.withValues(alpha: 0.5)),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: colour, letterSpacing: 0.4),
    ),
  );
}

// ---------------------------------------------------------------------------
// The warnings block
// ---------------------------------------------------------------------------

/// Red, collapsed, and **the approve button stays disabled until it has been
/// expanded at least once.** A warning nobody read is not a warning — and the
/// server enforces the same thing, because the app is not a security boundary.
class WarningBanner extends StatefulWidget {
  const WarningBanner({super.key, required this.warnings, required this.onExpanded});

  final List<RunWarning> warnings;
  final VoidCallback onExpanded;

  @override
  State<WarningBanner> createState() => _WarningBannerState();
}

class _WarningBannerState extends State<WarningBanner> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    if (widget.warnings.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.errorContainer,
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            title: Text(
              '${widget.warnings.length} baat dhyaan dene layak',
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w600,
                fontSize: 14.5,
              ),
            ),
            trailing: TextButton(
              onPressed: () {
                setState(() => _open = !_open);
                if (!_open) widget.onExpanded();
              },
              child: Text(_open ? 'chhupaiye' : 'dekhein'),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.warnings
                    .map((w) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('•  ', style: TextStyle(color: scheme.onErrorContainer)),
                              Expanded(
                                child: Text(
                                  w.messageHi,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.35,
                                    color: scheme.onErrorContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Expanding is what unlocks the button; the callback fires on open too.
    WidgetsBinding.instance.addPostFrameCallback((_) {});
  }
}

// ---------------------------------------------------------------------------
// One party row in the approval list
// ---------------------------------------------------------------------------

class PartyTile extends StatelessWidget {
  const PartyTile({
    super.key,
    required this.party,
    required this.included,
    required this.onToggle,
    required this.onTap,
  });

  final OutstandingParty party;
  final bool included;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sent = party.status == 'sent';
    final blocked = const {'reconcile_failed_server', 'blocked_no_template', 'failed'}
        .contains(party.status);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sent)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Icon(Icons.done_all, size: 20, color: Colors.green),
              )
            else if (blocked)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Icon(Icons.block, size: 20, color: scheme.error),
              )
            else
              Checkbox(value: included, onChanged: (v) => onToggle(v ?? false)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          party.partyName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            decoration: included || sent ? null : TextDecoration.lineThrough,
                            color: included || sent ? null : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (party.nameMismatchWarning) ...[
                        const SizedBox(width: 6),
                        const _Chip(text: 'NAAM ALAG', colour: Colors.amber),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${rupees(party.duePaise)}  ·  ${party.oldestDebitAgeDays ?? '—'} din  ·  ${party.billCount} bill',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // ⚠️ The FULL, UNMASKED number. Staff have to be able to
                    // verify it by eye against what they know — masking it here
                    // would defeat the entire point of the review screen.
                    '${party.waId != null ? prettyPhone(party.waId!) : 'number nahi'}'
                    '  ·  ${party.willUseTemplate ? 'template lagega' : 'chat khula hai'}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  if (blocked && party.skipReasonHi != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      party.skipReasonHi!,
                      style: TextStyle(fontSize: 12, color: scheme.error, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The bill table — BOTH ageing columns, always
// ---------------------------------------------------------------------------

/// The owner sees the two numbers side by side on every line, which is how the
/// "45 days since the bill, or 45 days past due?" ambiguity gets settled on the
/// first run rather than after a customer complains.
class AgeingTable extends StatelessWidget {
  const AgeingTable({super.key, required this.bills});

  final List<StatementBill> bills;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: Text(
            '"Din" = bill date se  ·  "Overdue" = due date ke baad se',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DataTable(
            headingRowHeight: 34,
            dataRowMinHeight: 34,
            dataRowMaxHeight: 40,
            columnSpacing: 18,
            columns: const [
              DataColumn(label: Text('Bill', style: TextStyle(fontSize: 12))),
              DataColumn(label: Text('Date', style: TextStyle(fontSize: 12))),
              DataColumn(label: Text('Due', style: TextStyle(fontSize: 12))),
              DataColumn(label: Text('Din', style: TextStyle(fontSize: 12)), numeric: true),
              DataColumn(label: Text('Overdue', style: TextStyle(fontSize: 12)), numeric: true),
              DataColumn(label: Text('Baaki', style: TextStyle(fontSize: 12)), numeric: true),
            ],
            rows: bills.map((b) {
              // A credit note or advance gets its own colour AND an explicit
              // tag. It must never read as another debt.
              final style = TextStyle(
                fontSize: 12.5,
                color: b.isCredit ? Colors.green.shade700 : null,
              );
              return DataRow(cells: [
                DataCell(Text(
                  '${b.billRef}${b.isAdvance ? ' (adv)' : b.isCredit ? ' (jama)' : ''}',
                  style: style,
                )),
                DataCell(Text(ddmmyyyy(b.billDateIso), style: style)),
                DataCell(Text(ddmmyyyy(b.dueDateIso), style: style)),
                DataCell(Text('${b.ageDays ?? '—'}', style: style)),
                DataCell(Text('${b.overdueDays ?? '—'}', style: style)),
                DataCell(Text(rupees(b.displayPaise), style: style)),
              ]);
            }).toList(),
          ),
        ),
      ],
    );
  }
}

/// The two figures R4 compared, shown side by side. When they differ, this is
/// the whole story of why a party was skipped.
class ReconcileRow extends StatelessWidget {
  const ReconcileRow({super.key, required this.billsSumPaise, required this.ledgerClosingPaise, required this.diffPaise});

  final int? billsSumPaise;
  final int? ledgerClosingPaise;
  final int? diffPaise;

  @override
  Widget build(BuildContext context) {
    if (billsSumPaise == null || ledgerClosingPaise == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final ok = (diffPaise ?? 0) == 0;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? scheme.surfaceContainerHighest : scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ok ? Icons.verified_outlined : Icons.error_outline,
                  size: 16, color: ok ? Colors.green.shade700 : scheme.error),
              const SizedBox(width: 8),
              Text(
                ok ? 'Hisaab milta hai' : 'Hisaab match nahi ho raha',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _kv('Bill-wise jod', rupees(-billsSumPaise!)),
          _kv('Ledger ka closing', rupees(-ledgerClosingPaise!)),
          if (!ok) _kv('Farak', rupees(-(diffPaise ?? 0))),
          if (!ok) ...[
            const SizedBox(height: 6),
            Text(
              'Aksar iska matlab hai ki koi receipt kisi bill par lagaayi nahi gayi ("On Account"). '
              'Jab tak ye match nahi hota, is party ko kuch nahi bhejenge.',
              style: TextStyle(fontSize: 12, height: 1.35, color: scheme.onErrorContainer),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: const TextStyle(fontSize: 12.5)),
        Text(v, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}
