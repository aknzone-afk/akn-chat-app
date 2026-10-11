import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/contacts/phone_contacts.dart';
import '../../../core/errors/failure.dart';
import '../../../core/format/formatters.dart';
import '../../../core/prefs/prefs.dart';
import '../../../core/widgets/states.dart';
import '../../auth/providers/auth_providers.dart';
import '../../chat/data/chat_actions.dart';
import '../../chat/providers/chat_providers.dart';
import '../../push/app_badge.dart';
import '../../push/push_providers.dart';
import '../../settings/providers/settings_providers.dart';
import '../../tally/presentation/widgets/tally_widgets.dart';
import '../domain/chat.dart';
import '../providers/chat_list_providers.dart';
import 'widgets/chat_list_skeleton.dart';
import 'widgets/chat_tile.dart';

/// Asked exactly once per install. See [_ChatListScreenState._askForNotifications].
const String _kAskedForPush = 'akn.askedForPush';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;

  /// The "today / Kal / weekday" column and the window dot both depend on the
  /// wall clock. One timer for the whole list, ticking a `ValueNotifier` — not
  /// `setState`, which would rebuild the `Scaffold` and hand the `ListView` a
  /// fresh delegate every minute.
  final _now = ValueNotifier<DateTime>(DateTime.now());
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _now.value = DateTime.now(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _askForNotifications());
  }

  /// Ask for notification permission HERE, and not at first launch.
  ///
  /// iOS only ever shows this dialog ONCE per install. Burning it on a splash
  /// screen, before the staff member has seen a single customer message, is
  /// unrecoverable: after a "Don't Allow" the only fix is Settings, and nobody
  /// goes there. So it waits until the chat list has actually rendered, and it
  /// is asked once per install.
  Future<void> _askForNotifications() async {
    if (!mounted) return;
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(_kAskedForPush) == true) return;
    if (ref.read(sessionProvider).status != SessionStatus.ready) return;
    await prefs.setBool(_kAskedForPush, true);
    await ref.read(pushServiceProvider).requestPermission();
  }

  @override
  void dispose() {
    _clock?.cancel();
    _now.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _stopSearching() {
    setState(() => _searching = false);
    _searchController.clear();
    ref.read(chatSearchProvider.notifier).clear();
    _searchFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // The iOS app-icon badge, pushed back DOWN.
    //
    // The server can only ever raise it (it stamps aps.badge on every push, and
    // a push means the count is above zero), so without this a night's unread
    // messages stayed on the icon all day after they had been read. This screen
    // is the right home for it: it is the only place with the whole chat list,
    // and it stays mounted underneath a pushed ChatScreen, so the badge keeps
    // following the count while staff are reading.
    // `watch`, not `listen`: this widget already rebuilds on every chat-list
    // snapshot through visibleChatsProvider below, so watching adds no rebuilds,
    // and it means the badge is corrected on the FIRST frame rather than only on
    // the next change. AppBadge.set dedupes and no-ops off iOS.
    unawaited(AppBadge.set(ref.watch(totalUnreadMessagesProvider)));

    final chatsAsync = ref.watch(chatsStreamProvider);
    final chats = ref.watch(visibleChatsProvider);
    final query = ref.watch(chatSearchProvider);

    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searching) _stopSearching();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: _searching ? 0 : null,
          leading: _searching
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _stopSearching,
                  tooltip: 'Wapas',
                )
              : null,
          title: _searching
              ? TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 16.5),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    hintText: 'Naam ya number dhoondein',
                    hintStyle: TextStyle(color: Colors.white60),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                  ),
                  onChanged: (v) => ref.read(chatSearchProvider.notifier).set(v),
                )
              : const _TitleWithCount(),
          actions: _searching
              ? [
                  if (query.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Saaf karein',
                      onPressed: () {
                        _searchController.clear();
                        ref.read(chatSearchProvider.notifier).clear();
                      },
                    ),
                ]
              : [
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Dhoondein',
                    onPressed: () => setState(() => _searching = true),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Settings',
                    onPressed: () => context.push(Routes.settings),
                  ),
                ],
        ),
        body: Column(
          children: [
            // Phase 6. ⚠️ THE HIGHEST-VALUE ALERT IN THE WHOLE FEATURE, and it
            // is here rather than in Settings on purpose.
            //
            // Logs on a shop PC are write-only media — nobody will ever open
            // them, and a monitor running ON the shop PC cannot tell you the
            // shop PC is off. This puts "the shop computer has not synced in
            // three days" in front of the person who cares, in the place he
            // already looks fifty times a day, in his own language. It costs
            // one document read and renders as nothing at all when everything
            // is fine.
            BridgeAlertBanner(onTap: () => context.push(Routes.tally)),
            const _NumberFilterBar(),
            const _DesignsBanner(),
            Expanded(
              child: switch (chatsAsync) {
                // Firestore's cache answers instantly on a warm start, so a
                // skeleton only ever shows on a genuinely cold one.
                AsyncValue(hasValue: false, hasError: false) => const ChatListSkeleton(),
                AsyncValue(hasError: true, hasValue: false, :final error?) => ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(chatsStreamProvider),
                ),
                _ => _ChatList(
                  chats: chats,
                  now: _now,
                  searching: query.isNotEmpty,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// "Sab · Unread · Reminders · Inquiries" — like WhatsApp's filter chips.
class _NumberFilterBar extends ConsumerWidget {
  const _NumberFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(numberLabelsProvider);
    final selected = ref.watch(numberFilterProvider);
    final filter = ref.read(numberFilterProvider.notifier);
    final unreadOnly = ref.watch(unreadOnlyProvider);
    final unreadChats = ref.watch(unreadChatCountProvider);

    Widget chip(String text, String? id) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(text),
        selected: !unreadOnly && selected == id,
        onSelected: (_) {
          ref.read(unreadOnlyProvider.notifier).set(false);
          filter.set(id);
        },
        visualDensity: VisualDensity.compact,
      ),
    );

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: [
          chip('Sab', null),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(unreadChats > 0 ? 'Unread $unreadChats' : 'Unread'),
              selected: unreadOnly,
              onSelected: (_) {
                filter.set(null);
                ref.read(unreadOnlyProvider.notifier).set(!unreadOnly);
              },
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (labels.length >= 2)
            for (final e in labels.entries) chip(e.value, e.key),
        ],
      ),
    );
  }
}

class _TitleWithCount extends ConsumerWidget {
  const _TitleWithCount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(unreadChatCountProvider);
    return Row(
      children: [
        const Text('AKN Chat'),
        if (waiting > 0) ...[
          const SizedBox(width: 9),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '$waiting',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ChatList extends ConsumerWidget {
  const _ChatList({
    required this.chats,
    required this.now,
    required this.searching,
  });

  final List<Chat> chats;
  final ValueNotifier<DateTime> now;
  final bool searching;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (chats.isEmpty) {
      return EmptyView(
        icon: searching ? Icons.search_off : Icons.chat_bubble_outline,
        title: searching ? 'Kuch nahi mila' : 'Abhi koi chat nahi',
        subtitle: searching
            ? 'Doosra naam ya number try karein.'
            : 'Customer pehle message karta hai. Jaise hi koi likhega, '
                  'chat yahan apne aap aa jaayegi.',
      );
    }

    final locallyRead = ref.watch(locallyReadProvider);
    final labels = ref.watch(numberLabelsProvider);
    final partyNames = ref.watch(partyNamesProvider).value ?? const <String, String>{};
    final phoneBook = ref.watch(phoneContactNamesProvider).value ?? const <String, String>{};
    final actions = ref.read(chatActionsProvider);

    return ValueListenableBuilder<DateTime>(
      valueListenable: now,
      builder: (context, tick, _) => ListView.separated(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: chats.length,
        // 3.44 renamed this on `.separated` only, and it takes ITEM indices —
        // no `* 2`.
        findItemIndexCallback: (key) {
          final waId = (key as ValueKey<String>).value;
          final index = chats.indexWhere((c) => c.waId == waId);
          return index < 0 ? null : index;
        },
        separatorBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(left: 77),
          child: Divider(
            height: 1,
            thickness: 0.6,
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        itemBuilder: (context, i) {
          final chat = chats[i];
          // 11-Oct-2026: near the end of what is loaded -> fetch 200 older chats.
          if (i >= chats.length - 5) {
            final loaded = ref.read(chatsStreamProvider).value?.length ?? 0;
            if (loaded >= ref.read(chatListLimitProvider)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if ((ref.read(chatsStreamProvider).value?.length ?? 0) >= ref.read(chatListLimitProvider)) {
                  ref.read(chatListLimitProvider.notifier).more();
                }
              });
            }
          }
          final markedAt = locallyRead[chat.waId];
          final isRead =
              markedAt != null &&
              (chat.lastMessageAt == null ||
                  !chat.lastMessageAt!.isAfter(markedAt));

          final title = chatTitle(chat, partyNames, phoneBook);
          final canMarkRead = chat.unreadCount > 0 && !isRead;
          final tile = ChatTile(
            chat: chat,
            now: tick,
            locallyRead: isRead,
            title: title,
            numberLabel: labels.length >= 2 ? labels[chat.phoneNumberId] : null,
            onTapDown: () => _prewarm(ref, chat.waId),
            onTap: () => context.push(Routes.chat(chat.waId)),
            onLongPress: () => _showChatActions(context, ref, chat, title),
          );
          // Swipe right → "Padh liya". The row never leaves the list
          // (confirmDismiss returns false); only the unread badge goes.
          return Dismissible(
            key: ValueKey(chat.waId),
            direction: canMarkRead ? DismissDirection.startToEnd : DismissDirection.none,
            background: const _SwipeReadBackground(),
            confirmDismiss: (_) async {
              _markRead(context, ref, actions, chat);
              return false;
            },
            child: tile,
          );
        },
      ),
    );
  }
}

/// Start the chat's message listener on touch-down; liveTailProvider keeps it
/// warm, so by the time the screen is pushed the messages are already there.
void _prewarm(WidgetRef ref, String waId) {
  final sub = ref.listenManual(liveTailProvider(waId), (_, _) {});
  Timer(const Duration(seconds: 2), sub.close);
}

void _markRead(BuildContext context, WidgetRef ref, ChatActions actions, Chat chat) {
  ref.read(locallyReadProvider.notifier).mark(chat.waId, chat.lastMessageAt ?? DateTime.now());
  unawaited(actions.markRead(chat.waId).catchError((Object e) {
    if (context.mounted) showAknSnack(context, describeError(e).message, isError: true);
  }));
}

class _SwipeReadBackground extends StatelessWidget {
  const _SwipeReadBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primaryContainer,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done_all, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text(
            'Padh liya',
            style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// "Customer ne designs bheje" — chats whose last customer message is a photo,
/// video or PDF nobody has opened yet. Tap to see only those chats.
class _DesignsBanner extends ConsumerWidget {
  const _DesignsBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(unseenDesignChatsProvider);
    final active = ref.watch(designsOnlyProvider);
    if (pending.isEmpty && !active) return const SizedBox.shrink();
    final partyNames = ref.watch(partyNamesProvider).value ?? const <String, String>{};
    final phoneBook = ref.watch(phoneContactNamesProvider).value ?? const <String, String>{};
    final scheme = Theme.of(context).colorScheme;
    final names = pending.take(3).map((c) => chatTitle(c, partyNames, phoneBook)).join(', ');
    final more = pending.length > 3 ? ' +${pending.length - 3}' : '';
    final notifier = ref.read(designsOnlyProvider.notifier);

    return Material(
      color: scheme.tertiaryContainer,
      child: InkWell(
        onTap: () => notifier.set(!active),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Icon(Icons.photo_library_outlined, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      pending.isEmpty
                          ? 'Sab designs dekh liye ✓'
                          : '📷 Customer ne designs bheje · ${pending.length}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                    if (pending.isNotEmpty)
                      Text(
                        '$names$more',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: scheme.onTertiaryContainer),
                      ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => notifier.set(!active),
                child: Text(active ? 'Sab chats' : 'Dekhein'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showChatActions(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  String title,
) async {
  final actions = ref.read(chatActionsProvider);
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(prettyPhone(chat.customerWaId)),
          ),
          const Divider(height: 1),
          if (chat.unreadCount > 0)
            ListTile(
              leading: const Icon(Icons.done_all),
              title: const Text('Padh liya mark karein'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _markRead(context, ref, actions, chat);
              },
            ),
          ListTile(
            leading: Icon(chat.pinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(chat.pinned ? 'Pin hataayein' : 'Pin karein'),
            onTap: () async {
              Navigator.of(sheetContext).pop();
              await _run(
                context,
                () => actions.setPinned(chat.waId, !chat.pinned),
                chat.pinned ? 'Pin hata diya' : 'Pin kar diya',
              );
            },
          ),
          if (chat.needsAttention)
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Attention hataayein'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _run(
                  context,
                  () => actions.clearAttention(chat.waId),
                  'Theek hai',
                );
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<void> _run(
  BuildContext context,
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
