import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme.dart';
import '../../../bot/domain/bot_log.dart';
import '../../../bot/providers/bot_log_providers.dart';

/// "Ye reply kyun?" — long-press any bot bubble.
///
/// The owner of a wholesale firm will not read Firestore. If he cannot audit
/// the bot inside the app, it is not audited — and the first question he will
/// ever ask about a bot message is "why did it say that?". This sheet answers
/// it on one screen: what the bot understood, how (regex or AI), what it read
/// out of the catalogue, which template rendered it, and what the call cost.
Future<void> showBotWhySheet(BuildContext context, String turnId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _BotWhySheet(turnId: turnId),
  );
}

class _BotWhySheet extends ConsumerWidget {
  const _BotWhySheet({required this.turnId});

  final String turnId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(botLogProvider(turnId));

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: switch (async) {
          AsyncValue(hasValue: false, hasError: true) => const _Pad(
            child: Text('Bot ka record nahi mil paaya.'),
          ),
          AsyncValue(hasValue: false) => const _Pad(
            child: Center(child: CircularProgressIndicator()),
          ),
          AsyncValue(value: null) => const _Pad(
            child: Text(
              'Is message ka record nahi hai.\n'
              'Purane record 90 din baad apne aap hat jaate hain.',
            ),
          ),
          AsyncValue(:final value?) => _Body(log: value),
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.log});

  final BotLog log;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final retrieval = log.retrieval;
    final snapshot = retrieval?['snapshot'];

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
      children: [
        Row(
          children: [
            const Text('🤖', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Ye reply kyun?',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        if (!log.egressPassed)
          _Warning(
            text:
                'Bot aisa number bhejne ja raha tha jo catalogue me nahi tha — '
                'message roka gaya. Ye ek bug hai: template ya persona check karein. '
                '${log.egressBlocked.join(", ")}',
          ),

        _Row(
          label: 'Customer ne likha',
          value: log.inboundText ?? '—',
        ),
        _Row(
          label: 'Kya samjha',
          value: [
            _intentLabel(log.intent),
            if (log.confidence != null)
              '${(log.confidence! * 100).round()}% pakka',
          ].join(' · '),
        ),
        _Row(
          label: 'Kaise',
          value: switch (log.route) {
            'regex' => 'Sirf pattern se${log.matchedPattern != null ? " · ${log.matchedPattern}" : ""} · AI nahi chalayi',
            'llm' => 'AI se${log.matchedPattern != null ? " · ${log.matchedPattern}" : ""}',
            'escalated' => 'Pattern ne insaan bulaya${log.escalationRule != null ? " · ${log.escalationRule}" : ""}',
            'owner_command' => 'Owner ka message — Phase 7 ka kaam',
            'suppressed' => 'Bot chup rakha gaya',
            'skipped' => 'Turn chhoda gaya',
            _ => log.route ?? '—',
          },
        ),
        if (log.escalationMatched != null)
          _Row(label: 'Kaunsa shabd', value: log.escalationMatched!),

        if (snapshot is Map) ...[
          const Divider(height: 26),
          _Row(
            label: 'Catalogue se',
            value: _catalogueLine(snapshot),
            emphasis: true,
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 6),
            child: Text(
              'Ye wahi values hain jo us waqt catalogue me thi — baad me CSV badal '
              'jaye to bhi ye record nahi badlega.',
              style: TextStyle(fontSize: 11.5, height: 1.3),
            ),
          ),
        ] else if (retrieval != null && retrieval['found'] == false)
          _Row(
            label: 'Catalogue se',
            value: 'Kuch nahi mila (${retrieval['id'] ?? '?'})',
          ),

        const Divider(height: 26),

        _Row(label: 'Kya kiya', value: log.headline),
        if (log.templateId != null) _Row(label: 'Template', value: log.templateId!),
        if (log.outboundText != null && log.outboundText!.isNotEmpty)
          _Row(label: 'Bheja', value: log.outboundText!),
        if (log.billRequestId != null)
          _Row(label: 'Bill job', value: '${log.billRequestId} · pending (Phase 6)'),
        if (log.needsAttentionSet)
          _Row(
            label: 'Attention',
            value: log.attentionReason ?? 'Chat flag ki gayi',
            emphasis: true,
          ),

        const Divider(height: 26),

        _Row(
          label: 'Kharcha',
          value: log.usedAi
              ? '₹${log.totalCostInr.toStringAsFixed(4)} · ${log.totalTokens} token'
              : '₹0.00 (koi AI call nahi)',
          emphasis: true,
        ),
        for (final call in log.aiCalls)
          _Row(
            label: call.purpose == 'classify' ? 'AI — samajhne me' : 'AI — likhne me',
            value: call.failed
                ? 'FAIL: ${call.errorMessage}'
                : '${call.model ?? "?"} · in ${call.inputTokens} / out ${call.outputTokens}'
                      '${call.thoughtTokens > 0 ? " (+${call.thoughtTokens} soch)" : ""}'
                      ' · ${call.latencyMs ?? "?"}ms'
                      '${call.finishReason != null && call.finishReason != "STOP" ? " · ${call.finishReason}" : ""}',
          ),
        if (log.aiCalls.isNotEmpty)
          _Row(
            label: 'Prompt version',
            value: log.aiCalls.first.promptVersion ?? '—',
          ),
        if (log.durationMs != null)
          _Row(
            label: 'Lagaa time',
            value:
                '${(log.durationMs! / 1000).toStringAsFixed(1)}s'
                '${log.settleMs != null ? " (${(log.settleMs! / 1000).toStringAsFixed(0)}s intezaar samet)" : ""}',
          ),
      ],
    );
  }

  static String _intentLabel(String? intent) => switch (intent) {
    'bill_request' => 'Bill maanga',
    'design_price' => 'Design ka rate',
    'catalog_request' => 'Catalogue maanga',
    'greeting' => 'Sirf namaste',
    'human_needed' => 'Insaan chahiye',
    'other' => 'Kuch aur',
    null => 'Samajh nahi aaya',
    _ => intent,
  };

  static String _catalogueLine(Map<dynamic, dynamic> s) {
    final parts = <String>[];
    if (s['designNo'] != null) parts.add('Design ${s['designNo']}');
    if (s['wholesalePrice'] != null) parts.add('₹${s['wholesalePrice']}');
    if (s['moq'] != null) parts.add('MOQ ${s['moq']}');
    if (s['fabric'] != null) parts.add('${s['fabric']}');
    if (s['billNo'] != null) parts.add('Bill ${s['billNo']}');
    if (s['priceAgeDays'] != null) parts.add('rate ${s['priceAgeDays']} din purana');
    if (s['active'] == false) parts.add('BAND hai');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.emphasis = false});

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 14,
              height: 1.35,
              fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
              color: emphasis ? scheme.primary : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AknColors.attentionInkDark : AknColors.attentionInk;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: isDark ? AknColors.attentionDark : AknColors.attentionLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.gpp_maybe_outlined, size: 18, color: ink),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.35, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pad extends StatelessWidget {
  const _Pad({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(28), child: child);
}
