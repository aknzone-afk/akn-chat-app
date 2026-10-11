import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/errors/failure.dart';
import '../../../core/format/formatters.dart';
import '../../../core/prefs/prefs.dart';
import '../../../core/widgets/shimmer.dart';
import '../../../core/widgets/states.dart';
import '../../auth/providers/auth_providers.dart';
import '../../bot/providers/bot_log_providers.dart';
import '../../tally/providers/tally_providers.dart';
import '../data/settings_actions.dart';
import '../domain/app_settings.dart';
import '../providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final session = ref.watch(sessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: switch (settingsAsync) {
        AsyncValue(hasValue: false, hasError: true, :final error?) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(appSettingsProvider),
        ),
        // Skeleton, never a blocking spinner — the same rule the chat list and
        // the conversation follow.
        AsyncValue(hasValue: false) => const _SettingsSkeleton(),
        AsyncValue(:final value?) => _SettingsBody(
          settings: value,
          staffName: session.staff?.name ?? session.user?.email ?? '',
          email: session.user?.email ?? '',
          isOwner: session.staff?.owner == true,
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _SettingsBody extends ConsumerWidget {
  const _SettingsBody({
    required this.settings,
    required this.staffName,
    required this.email,
    required this.isOwner,
  });

  final AppSettings settings;
  final String staffName;
  final String email;

  /// `staff/{uid}.owner`. The persona and the global bot switch are refused by
  /// the backend for anybody else, so the controls are hidden rather than
  /// offered and then rejected.
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _AccountCard(name: staffName, email: email),

        if (settings.needsReseed) const _ReseedNotice(),

        const _SectionHeader('Bot'),
        if (!settings.botGlobalEnabled) const _BillingWarning(),
        SwitchListTile(
          value: settings.botGlobalEnabled,
          // Owner only, and the backend enforces it too — this just avoids
          // offering a tap that would come back "permission-denied".
          onChanged: isOwner
              ? (v) => _run(
                  context,
                  ref,
                  () => ref
                      .read(settingsActionsProvider)
                      .setBotGlobalEnabled(v),
                  v ? 'Bot chalu kar diya' : 'Bot band kar diya',
                )
              : null,
          secondary: Icon(
            settings.botGlobalEnabled
                ? Icons.smart_toy
                : Icons.smart_toy_outlined,
            color: settings.botGlobalEnabled ? AknColors.gold : null,
          ),
          title: const Text('Bot globally chalu'),
          subtitle: Text(
            settings.botGlobalEnabled
                ? 'Sab chats me bot jawab de sakta hai'
                : isOwner
                ? 'Bot band hai — chalu karne se pehle neeche wali warning padhein'
                : 'Bot band hai — sirf owner chalu kar sakte hain',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.record_voice_over_outlined),
          title: const Text('Bot ki bhaasha'),
          subtitle: Text(
            isOwner
                ? 'Bot kaise baat kare — persona edit karein'
                : 'Sirf owner badal sakte hain',
          ),
          trailing: const Icon(Icons.chevron_right),
          enabled: isOwner,
          onTap: isOwner ? () => context.push(Routes.persona) : null,
        ),
        ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('Bot ne kya kiya'),
          subtitle: const Text('Har reply, har chup rehna, aur kharcha'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(Routes.botActivity),
        ),
        ListTile(
          leading: const Icon(Icons.pause_circle_outline),
          title: const Text('Bot pause minutes'),
          subtitle: const Text(
            'Staff ke reply karne par bot itni der chup rahega',
          ),
          trailing: Text(
            '${settings.botPauseMinutes} min',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => _pickNumber(
            context,
            ref,
            title: 'Bot kitni der chup rahe?',
            options: const [30, 60, 120, 240, 480],
            current: settings.botPauseMinutes,
            suffix: 'min',
            apply: (v) =>
                ref.read(settingsActionsProvider).setBotPauseMinutes(v),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.speed_outlined),
          title: const Text('10 minute me zyada se zyada reply'),
          subtitle: const Text('Ek chat me. Loop se bachne ke liye.'),
          trailing: Text(
            '${settings.botReplyMaxPer10Min}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => _pickNumber(
            context,
            ref,
            title: '10 minute me kitne reply?',
            options: const [1, 2, 3, 5],
            current: settings.botReplyMaxPer10Min,
            suffix: '',
            apply: (v) =>
                ref.read(settingsActionsProvider).setBotReplyMaxPer10Min(v),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.event_busy_outlined),
          title: const Text('Rate kitna purana chalega'),
          subtitle: const Text(
            'Isse purana rate bot NAHI batayega — team ko bulayega',
          ),
          trailing: Text(
            settings.productPriceMaxAgeDays == 0
                ? 'koi limit nahi'
                : '${settings.productPriceMaxAgeDays} din',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => _pickNumber(
            context,
            ref,
            title: 'Rate kitne din tak bhejein?',
            options: const [15, 30, 60, 90, 180],
            current: settings.productPriceMaxAgeDays,
            suffix: 'din',
            apply: (v) => ref
                .read(settingsActionsProvider)
                .setProductPriceMaxAgeDays(v),
          ),
        ),
        SwitchListTile(
          value: settings.botDisclosure,
          onChanged: (v) => _run(
            context,
            ref,
            () => ref.read(settingsActionsProvider).setBotDisclosure(v),
            'Save ho gaya',
          ),
          secondary: const Icon(Icons.campaign_outlined),
          title: const Text('"Auto reply" likha jaye'),
          subtitle: const Text(
            'Har 24 ghante me pehle bot message par ek line — taaki customer ko '
            'pata rahe',
          ),
        ),
        const _PendingBillsRow(),

        const _SectionHeader('Tally'),
        const _TallyRow(),

        const _SectionHeader('WhatsApp'),
        SwitchListTile(
          value: settings.sendReadReceipts,
          onChanged: (v) => _run(
            context,
            ref,
            () => ref.read(settingsActionsProvider).setSendReadReceipts(v),
            'Save ho gaya',
          ),
          secondary: const Icon(Icons.done_all),
          title: const Text('Blue tick bhejein'),
          subtitle: Text(
            settings.sendReadReceipts
                ? 'Customer ko dikhta hai ki aapne padh liya'
                : 'Customer ko blue tick nahi dikhega',
          ),
        ),

        const _SectionHeader('Owner numbers'),
        if (settings.ownerNumbers.isEmpty)
          const ListTile(
            leading: Icon(Icons.person_off_outlined),
            title: Text('Koi owner number set nahi hai'),
          )
        else
          ...settings.ownerNumbers.map(
            (number) => ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(prettyPhone(number)),
              subtitle: Text(number),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy karein',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: number));
                  if (!context.mounted) return;
                  showAknSnack(context, 'Number copy ho gaya');
                },
              ),
            ),
          ),

        _SectionHeader('Quick replies (${settings.quickReplies.length})'),
        if (settings.quickReplies.isEmpty)
          const ListTile(
            leading: Icon(Icons.bolt_outlined),
            title: Text('Koi quick reply set nahi hai'),
            subtitle: Text('App shipped defaults dikha rahi hai.'),
          )
        else
          ...settings.quickReplies.map(
            (reply) => ListTile(
              dense: true,
              leading: const Icon(Icons.bolt_outlined, size: 20),
              title: Text(reply),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy karein',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: reply));
                  if (!context.mounted) return;
                  showAknSnack(context, 'Copy ho gaya');
                },
              ),
            ),
          ),

        const _SectionHeader('App'),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('Theme'),
          subtitle: Text(switch (themeMode) {
            ThemeMode.light => 'Hamesha light',
            ThemeMode.dark => 'Hamesha dark',
            ThemeMode.system => 'Phone ke hisaab se',
          }),
          trailing: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: const [
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined, size: 18),
              ),
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.phone_android, size: 18),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined, size: 18),
              ),
            ],
            selected: {themeMode},
            onSelectionChanged: (s) =>
                ref.read(themeModeProvider.notifier).set(s.first),
          ),
        ),

        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => _confirmSignOut(context, ref),
            icon: const Icon(Icons.logout, size: 19),
            label: const Text('Sign out karein'),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'AKN Chat · Phase 5 · Gemini bot',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out karein?'),
        content: const Text(
          'Dobara sign in karne ke liye email aur password chahiye honge.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Rehne dein'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authActionsProvider).signOut();
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.name, required this.email});

  final String name;
  final String email;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AknColors.maroon,
              shape: BoxShape.circle,
            ),
            child: Text(
              (name.isEmpty ? '?' : name.substring(0, 1)).toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name.isEmpty ? 'Staff' : name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (email.isNotEmpty)
                  Text(
                    email,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Settings body while `settings/app` loads.
///
/// Same geometry as the real list, so the swap is a cross-fade rather than a
/// jump — and no blocking spinner, which is the rule everywhere else in the app.
class _SettingsSkeleton extends StatelessWidget {
  const _SettingsSkeleton();

  static const _rows = [54.0, 54.0, 44.0, 54.0, 70.0, 44.0, 90.0];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return RepaintBoundary(
      child: Shimmer(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            for (final h in _rows) ...[
              Bone(width: width, height: h, radius: 12),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

/// An amber note. Two of them exist and they say very different things.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AknColors.attentionInkDark : AknColors.attentionInk;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AknColors.attentionDark : AknColors.attentionLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: ink),
          const SizedBox(width: 10),
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

/// `settings/app` is still on schemaVersion 2, so every Phase 5 key is missing
/// and the bot is running on the code defaults rather than on anything the
/// owner has chosen. Re-running `seedOnce` fills ONLY what is absent.
class _ReseedNotice extends StatelessWidget {
  const _ReseedNotice();

  @override
  Widget build(BuildContext context) => const _Notice(
    icon: Icons.system_update_alt,
    text:
        'settings/app purana hai (Phase 5 ki keys nahi hain). Bot code ke '
        'defaults par chal raha hai. seedOnce dobara chalayein — wo sirf missing '
        'keys bharta hai, aapki tuning ko haath nahi lagata.',
  );
}

/// The one thing that must be true before the bot is armed.
///
/// Google's FREE Gemini tier explicitly uses prompts to improve their products,
/// and the WhatsApp Business Solution Terms forbid Business Solution Data being
/// used to train anybody's AI. Running customer messages through a free-tier
/// key is therefore a terms breach — and the free tier's ~250 requests a day
/// would not run this bot in any case.
class _BillingWarning extends StatelessWidget {
  const _BillingWarning();

  @override
  Widget build(BuildContext context) => const _Notice(
    icon: Icons.warning_amber_rounded,
    text:
        'Bot chalu karne se pehle: Gemini API key par BILLING lagi honi chahiye, '
        'aur wo key TallyQueryBot wali key se alag honi chahiye. Free tier '
        'customer ke message Google ki training me daal deta hai — jo WhatsApp '
        'ki terms ke khilaaf hai.',
  );
}

/// "3 bill nikal rahe hain" — the Phase 6 queue, visible so a stuck job is
/// noticed by staff and not by the customer.
class _PendingBillsRow extends ConsumerWidget {
  const _PendingBillsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingBillRequestsProvider).value ?? const [];
    if (pending.isEmpty) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text('${pending.length} bill request pending'),
      subtitle: const Text(
        'Tally bridge inhe utha raha hai — 1-2 minute me chale jaate hain',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(Routes.botActivity),
    );
  }
}

/// The Tally section's single entry point.
///
/// It shows the ONE thing the owner needs to know at a glance: is there a batch
/// waiting for his tap, and is the shop computer alive. Everything else lives
/// behind it.
class _TallyRow extends ConsumerWidget {
  const _TallyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingRun = ref.watch(pendingRunProvider);
    final alert = ref.watch(bridgeAlertProvider);
    final control = ref.watch(bridgeControlProvider).value;
    final scheme = Theme.of(context).colorScheme;

    final subtitle = alert ??
        (pendingRun != null
            ? '${pendingRun.partyCount} party ka batch aapke approve ka intezaar kar raha hai'
            : control?.killSwitch == true
                ? 'Sab kuch ruka hua hai (kill switch on)'
                : 'Outstanding, bill aur bilty — sab yahan se');

    return ListTile(
      leading: Badge(
        isLabelVisible: pendingRun != null,
        label: Text('${pendingRun?.partyCount ?? 0}'),
        child: Icon(
          Icons.account_balance_outlined,
          color: alert != null ? scheme.error : null,
        ),
      ),
      title: const Text('Tally se WhatsApp'),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: alert != null ? scheme.error : null),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(Routes.tally),
    );
  }
}

/// Run a settings write and say what happened. Every control on this screen
/// goes through it, so a permission-denied from the owner gate is never silent.
Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() op,
  String okMessage,
) async {
  try {
    await op();
    if (!context.mounted) return;
    showAknSnack(context, okMessage);
  } catch (e) {
    if (!context.mounted) return;
    showAknSnack(context, describeError(e).message, isError: true);
  }
}

/// A small "pick one of these numbers" sheet. Deliberately a fixed list rather
/// than a text field: these are rails, and a typo in one of them is a bot that
/// answers twenty times or quotes a six-month-old rate.
Future<void> _pickNumber(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required List<int> options,
  required int current,
  required String suffix,
  required Future<void> Function(int) apply,
}) async {
  final chosen = await showModalBottomSheet<int>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          for (final option in options)
            ListTile(
              title: Text(suffix.isEmpty ? '$option' : '$option $suffix'),
              trailing: option == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(sheetContext).pop(option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (chosen == null || chosen == current) return;
  if (!context.mounted) return;
  await _run(context, ref, () => apply(chosen), 'Save ho gaya');
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 20, 18, 6),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
