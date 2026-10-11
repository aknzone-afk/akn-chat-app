import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/format/formatters.dart';
import '../../../core/widgets/states.dart';
import '../domain/bot_log.dart';
import '../providers/bot_log_providers.dart';

/// "Bot ne aaj kya kiya" — Settings → Bot.
///
/// Every turn the bot took, INCLUDING the ones where it deliberately said
/// nothing. "Why did the bot NOT reply?" is asked as often as the inverse, and
/// a missing row looks exactly like a crash.
///
/// This screen exists because the owner of a wholesale firm will not read
/// Firestore. If he cannot see what the bot has been doing — and what it cost —
/// inside the app, the bot is not audited, and an unaudited bot is one he will
/// eventually switch off out of unease rather than evidence.
class BotActivityScreen extends ConsumerWidget {
  const BotActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(recentBotLogsProvider);
    final cost = ref.watch(botCostTodayProvider);
    final pending = ref.watch(pendingBillRequestsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Bot ne kya kiya')),
      body: switch (async) {
        AsyncValue(hasValue: false, hasError: true, :final error?) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(recentBotLogsProvider),
        ),
        AsyncValue(hasValue: false) => const Center(
          child: CircularProgressIndicator(),
        ),
        AsyncValue(:final value?) => _Body(
          logs: value,
          costInr: cost.inr,
          turns: cost.turns,
          aiTurns: cost.aiTurns,
          turnsCapped: cost.capped,
          pendingBills: pending.length,
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.logs,
    required this.costInr,
    required this.turns,
    required this.aiTurns,
    required this.turnsCapped,
    required this.pendingBills,
  });

  final List<BotLog> logs;
  final double costInr;
  final int turns;
  final int aiTurns;

  /// The 24-hour query hit its 500-row ceiling, so these figures are a floor.
  final bool turnsCapped;
  final int pendingBills;

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Bot ne abhi tak kuch nahi kiya.\n'
            'Settings me "Bot globally chalu" on karein.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: logs.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _SummaryCard(
            costInr: costInr,
            turns: turns,
            aiTurns: aiTurns,
            turnsCapped: turnsCapped,
            pendingBills: pendingBills,
          );
        }
        return _LogTile(log: logs[index - 1]);
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.costInr,
    required this.turns,
    required this.aiTurns,
    required this.turnsCapped,
    required this.pendingBills,
  });

  final double costInr;
  final int turns;
  final int aiTurns;
  final bool turnsCapped;
  final int pendingBills;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pichhle 24 ghante',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Stat(
                value: turnsCapped ? '500+' : '$turns',
                label: 'message dekhe',
              ),
              _Stat(value: '$aiTurns', label: 'AI chali'),
              _Stat(
                value: '₹${costInr.toStringAsFixed(2)}',
                label: 'kharcha',
              ),
              if (pendingBills > 0)
                _Stat(value: '$pendingBills', label: 'bill pending'),
            ],
          ),
          if (aiTurns < turns) ...[
            const SizedBox(height: 8),
            Text(
              '${turns - aiTurns} message sirf pattern se handle hue — un par '
              'ek paisa kharch nahi hua.',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log});

  final BotLog log;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final (icon, colour) = switch (log.action) {
      'replied' => (
        Icons.smart_toy_outlined,
        isDark ? AknColors.botPausedInkDark : AknColors.botPausedInk,
      ),
      'attention_only' => (
        Icons.pan_tool_outlined,
        isDark ? AknColors.attentionInkDark : AknColors.attentionInk,
      ),
      _ => (Icons.remove_circle_outline, scheme.onSurfaceVariant),
    };

    return ListTile(
      dense: true,
      leading: Icon(
        log.egressPassed ? icon : Icons.gpp_bad_outlined,
        size: 22,
        color: log.egressPassed ? colour : scheme.error,
      ),
      title: Text(
        log.headline,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          log.chatName ?? (log.waId == null ? '' : prettyPhone(log.waId!)),
          if (log.inboundText != null && log.inboundText!.isNotEmpty)
            '"${log.inboundText}"',
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            log.ts == null ? '' : chatListTime(log.ts!, DateTime.now()),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          Text(
            log.usedAi ? '₹${log.totalCostInr.toStringAsFixed(3)}' : 'free',
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
      onTap: log.waId == null
          ? null
          : () => context.push(Routes.chat(log.waId!)),
    );
  }
}
