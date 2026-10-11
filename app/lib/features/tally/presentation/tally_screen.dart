import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/tally_actions.dart';
import '../domain/tally_models.dart';
import '../providers/tally_providers.dart';
import 'widgets/tally_widgets.dart';

/// Settings → Tally. The hub.
class TallyScreen extends ConsumerWidget {
  const TallyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(recentRunsProvider).value ?? const <OutstandingRun>[];
    final pending = ref.watch(pendingRunProvider);
    final control = ref.watch(bridgeControlProvider).value;
    final counters = ref.watch(tallyCountersTodayProvider).value ?? const {};
    final problems = ref.watch(problemPartiesProvider).value ?? const [];
    final settings = ref.watch(appSettingsProvider).value;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Tally')),
      body: ListView(
        children: [
          const BridgeHealthCard(),

          // ⚠️ tallyGlobalEnabled ships FALSE, mirroring botGlobalEnabled.
          // Nothing reaches a customer until somebody deliberately arms it.
          if (settings != null && !settings.tallyGlobalEnabled)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Tally se WhatsApp bhejna abhi chalu nahi kiya gaya hai. '
                'Jab tak ye on nahi hota, kisi customer ko kuch nahi jaayega.',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
            ),

          if (pending != null) _PendingRunCard(run: pending),

          _Section(
            title: 'Outstanding',
            children: [
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('Pichhle run'),
                subtitle: Text(
                  runs.isEmpty ? 'Abhi tak koi run nahi bana' : '${runs.length} run',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => _RunHistorySheet(runs: runs),
                ),
              ),
              ListTile(
                leading: Badge(
                  isLabelVisible: problems.isNotEmpty,
                  label: Text('${problems.length}'),
                  child: const Icon(Icons.phone_disabled_outlined),
                ),
                title: const Text('Kis-kis ko nahi bheja, aur kyun'),
                subtitle: Text(
                  problems.isEmpty
                      ? 'Sab party ke number theek hain'
                      : '${problems.length} party ke number me masla hai',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(Routes.tallySkipped),
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Kya-kya bheja gaya'),
                subtitle: Text(
                  'Aaj: ${counters['total'] ?? 0} message '
                  '(${counters['statements'] ?? 0} statement, ${counters['bills'] ?? 0} bill)',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(Routes.tallySent),
              ),
            ],
          ),

          _Section(
            title: 'Control',
            children: [
              _KillSwitchTile(control: control),
              SwitchListTile(
                secondary: const Icon(Icons.science_outlined),
                title: const Text('Dry run'),
                subtitle: const Text(
                  'Sab kuch banega, dikhega bhi — lekin kisi customer ko kuch nahi jaayega.',
                ),
                value: control?.dryRun ?? false,
                onChanged: (v) => _guard(context, () => ref.read(tallyActionsProvider).setMode(dryRun: v)),
              ),
              ListTile(
                leading: const Icon(Icons.phone_iphone),
                title: const Text('Rehearsal number'),
                subtitle: Text(
                  control?.rehearsalTo == null
                      ? 'Band hai — message asli customer ko jaayenge'
                      : 'Sab message +${control!.rehearsalTo} par jaayenge, customer ko nahi',
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editRehearsal(context, ref, control?.rehearsalTo),
              ),
              _ModeTile(
                icon: Icons.receipt_outlined,
                label: 'Bill bhejna',
                mode: control?.billMode ?? 'rehearsal',
                onChanged: (m) => _guard(context, () => ref.read(tallyActionsProvider).setMode(billMode: m)),
              ),
              _ModeTile(
                icon: Icons.local_shipping_outlined,
                label: 'Bilty bhejna',
                mode: control?.biltyMode ?? 'rehearsal',
                onChanged: (m) => _guard(context, () => ref.read(tallyActionsProvider).setMode(biltyMode: m)),
              ),
            ],
          ),

          _Section(
            title: 'Shop computer',
            children: [
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('Abhi run banwaiye'),
                subtitle: const Text('Agle cycle par bridge naya outstanding run banayega'),
                onTap: () => _guard(context, () => ref.read(tallyActionsProvider).runNow(),
                    ok: 'Bridge ko keh diya. Ek-do minute me run ban jaayega.'),
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Party list dobara padhiye'),
                subtitle: const Text('Tally me mobile number badla ho to ye dabaiye'),
                onTap: () => _guard(context, () => ref.read(tallyActionsProvider).refreshLedgers(),
                    ok: 'Bridge ko keh diya.'),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static Future<void> _editRehearsal(BuildContext context, WidgetRef ref, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final value = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rehearsal number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Rehearsal me har message ASLI ME BHEJA JAATA HAI — asli PDF, asli template, '
              'asli caption — lekin customer ke bajaye is number par. Caption me customer ka '
              'naam aur number likha rehta hai, taaki aap mila sakein.',
              style: TextStyle(fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'WhatsApp number',
                hintText: '919876543210',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Rehne dijiye')),
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Band kijiye')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Set kijiye'),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    await _guard(context, () => ref.read(tallyActionsProvider).setMode(rehearsalTo: value));
  }

  static Future<void> _guard(BuildContext context, Future<void> Function() op, {String? ok}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op();
      messenger.showSnackBar(SnackBar(content: Text(ok ?? 'Ho gaya')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _PendingRunCard extends ConsumerWidget {
  const _PendingRunCard({required this.run});
  final OutstandingRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.primaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(Routes.tallyRun(run.runId)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ek batch aapke dekhne ka intezaar kar raha hai',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${run.partyCount} party  ·  ${rupees(run.totalPaise)}'
                '${run.oldestDebitAgeDays != null ? '  ·  sabse purana ${run.oldestDebitAgeDays} din' : ''}',
                style: TextStyle(fontSize: 13.5, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => context.push(Routes.tallyRun(run.runId)),
                child: const Text('Dekhiye aur bhejiye'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KillSwitchTile extends ConsumerWidget {
  const _KillSwitchTile({required this.control});
  final BridgeControl? control;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = control?.killSwitch ?? false;
    return SwitchListTile(
      secondary: Icon(Icons.power_settings_new, color: on ? Theme.of(context).colorScheme.error : null),
      title: const Text('Sab kuch rok dijiye'),
      subtitle: Text(
        on
            ? 'RUKA HUA HAI. Koi statement, bill ya bilty nahi jaayega.'
            : 'Ek dabane par sab band. Bheja hua wapas nahi aata, baaki ruk jaata hai.',
      ),
      value: on,
      onChanged: (value) async {
        if (value) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Sab kuch rok dein?'),
              content: const Text(
                'Iske baad koi bhi statement, bill ya bilty nahi jaayega — jab tak aap dobara '
                'chalu nahi karte. Jo message ja chuke hain woh wapas nahi aayenge.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Rehne dijiye')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
                  child: const Text('Haan, rok dijiye'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
        }
        if (!context.mounted) return;
        await TallyScreen._guard(context, () => ref.read(tallyActionsProvider).setKillSwitch(value));
      },
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.icon,
    required this.label,
    required this.mode,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    subtitle: Text(switch (mode) {
      'off' => 'Band hai',
      'rehearsal' => 'Rehearsal — message rehearsal number par jaate hain',
      'live' => 'CHALU — asli customer ko jaate hain',
      _ => mode,
    }),
    trailing: SegmentedButton<String>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(value: 'off', label: Text('Band')),
        ButtonSegment(value: 'rehearsal', label: Text('Reh.')),
        ButtonSegment(value: 'live', label: Text('Chalu')),
      ],
      selected: {mode},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
  );
}

class _RunHistorySheet extends StatelessWidget {
  const _RunHistorySheet({required this.runs});
  final List<OutstandingRun> runs;

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    children: runs
        .map((r) => ListTile(
              title: Text(r.runId),
              subtitle: Text('${r.statusHi}  ·  ${r.partyCount} party  ·  ${rupees(r.totalPaise)}'),
              trailing: r.sentCount > 0 ? Text('${r.sentCount} gaye') : null,
              onTap: () {
                Navigator.pop(context);
                context.push(Routes.tallyRun(r.runId));
              },
            ))
        .toList(),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
      ...children,
    ],
  );
}
