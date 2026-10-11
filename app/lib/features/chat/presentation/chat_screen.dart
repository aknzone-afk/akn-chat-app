import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../core/contacts/phone_contacts.dart';
import '../../../core/errors/failure.dart';
import '../../../core/format/formatters.dart';
import '../../../core/widgets/avatar_initials.dart';
import '../../../core/widgets/states.dart';
import '../../chats/domain/chat.dart';
import '../../push/push_providers.dart';
import '../../push/push_service.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/chat_actions.dart';
import '../data/message_repository.dart';
import '../providers/chat_providers.dart';
import '../providers/media_providers.dart';
import 'widgets/attention_banner.dart';
import 'widgets/bot_paused_banner.dart';
import 'widgets/composer.dart';
import 'widgets/date_chip.dart';
import 'widgets/jump_to_bottom_fab.dart';
import 'widgets/message_list.dart';
import 'widgets/rename_sheet.dart';
import '../../chats/providers/chat_list_providers.dart';

/// How often the 24-hour countdown reprints. Twenty seconds is well under the
/// one-minute resolution the label shows, and it is cheap because the tick
/// drives a `ValueNotifier` inside a `RepaintBoundary` and never touches the
/// list.
const _windowTickPeriod = Duration(seconds: 20);

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.waId});

  final String waId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();

  // Everything below is a ValueNotifier rather than `setState`, on purpose.
  // `setState` here would rebuild the Scaffold → the ListView widget → a fresh
  // SliverChildBuilderDelegate → `shouldRebuild` on every visible bubble.
  final _showFab = ValueNotifier<bool>(false);
  final _fabUnread = ValueNotifier<int>(0);
  final _stickyDate = ValueNotifier<DateTime?>(null);
  final _stickyVisible = ValueNotifier<bool>(false);
  final _windowTick = ValueNotifier<DateTime>(DateTime.now());

  /// Briefly tints the bubble a quoted reply jumped to, so staff can see which
  /// message the tap actually meant.
  final _flashId = ValueNotifier<String?>(null);

  Timer? _windowTimer;
  Timer? _stickyHideTimer;
  Timer? _flashTimer;
  DateTime _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Every message id the live tail has already shown us.
  Set<String>? _knownIds;
  DateTime? _lastMarkReadAt;
  bool _marking = false;

  /// Captured while the element is still mounted, and that is not a style
  /// preference — composer.dart carries the same note for the same reason.
  ///
  /// `ConsumerStatefulElement.read()` runs `_assertNotDisposed()` first, which
  /// is a plain `if (!context.mounted) throw StateError(...)` — not an assert,
  /// so it throws in release too. `StatefulElement.unmount()` calls
  /// `super.unmount()` (clearing `_widget`, so `mounted` is already false)
  /// BEFORE `state.dispose()`. So `ref.read(...)` inside dispose() threw on
  /// EVERY chat exit, and the throw aborted the rest of this method: the voice
  /// note kept playing over the chat list with no player anywhere to pause it,
  /// the presence claim and its 45-second heartbeat were never released (so that
  /// customer's messages stopped buzzing on this phone indefinitely), and the
  /// window timer, the scroll controller and six ValueNotifiers leaked per chat
  /// opened.
  late final PushService _push;
  late final VoicePlayer _voice;

  @override
  void initState() {
    super.initState();
    _push = ref.read(pushServiceProvider);
    _voice = ref.read(voicePlayerProvider.notifier);
    _scroll.addListener(_onScroll);
    _windowTimer = Timer.periodic(
      _windowTickPeriod,
      (_) => _windowTick.value = DateTime.now(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());

    // "This device has this chat open." Written into our own element of
    // staff/{uid}.fcmTokens, which is the only place the backend can read it
    // AND one of the only two fields firestore.rules lets a phone write. It is
    // what stops a push buzzing on the very phone that is already showing the
    // message. See functions/lib/push.js.
    unawaited(_push.setOpenChat(widget.waId));

    // Android can kill the app while the camera activity is foregrounded on a
    // low-memory device. Without this the photo they just took is silently
    // gone, with no error anywhere.
    unawaited(_recoverLostCapture());
  }

  /// The SAME State, a DIFFERENT chat.
  ///
  /// go_router keys a page by the PATH PATTERN, not the location —
  /// `match.dart` builds `pageKey: ValueKey(newMatchedPath)` where
  /// `newMatchedPath` is `/chats/:waId` — so `/chats/A` and `/chats/B` produce
  /// identical page keys, `Page.canUpdate` returns true, and the Navigator
  /// UPDATES THIS ROUTE IN PLACE. initState never runs again.
  ///
  /// That path is reached whenever a notification is tapped while a
  /// notification-opened chat is already showing (app.dart navigates with
  /// `go`). Without this override the screen showed Kalpana while
  /// `openChatProvider` still said Ramesh: every further message from Kalpana
  /// buzzed the phone displaying Kalpana, messages from Ramesh were silently
  /// suppressed on a phone not showing Ramesh, and `_markRead` never re-ran so
  /// Kalpana's unread badge stayed lit on all four phones and she never got a
  /// blue tick.
  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.waId == widget.waId) return;

    _knownIds = null; // "first snapshot for this chat" again
    _lastMarkReadAt = null; // and a fresh markRead debounce
    _fabUnread.value = 0;
    _flashId.value = null;
    _stickyVisible.value = false;
    // The list keeps whatever offset the PREVIOUS chat was scrolled to, which
    // would drop the staff member into the middle of a different conversation's
    // history. 0 is the bottom in a reversed list.
    if (_scroll.hasClients) _scroll.jumpTo(0);

    unawaited(_voice.stop());
    unawaited(_push.setOpenChat(widget.waId));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _markRead();
    });
  }

  Future<void> _recoverLostCapture() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final lost = await ImagePicker().retrieveLostData();
      if (lost.isEmpty || lost.file == null) return;
      debugPrint('recovered a lost capture: ${lost.file!.path}');
    } catch (_) {
      // Nothing to recover, or the platform said no. Never worth surfacing.
    }
  }

  @override
  void dispose() {
    // Release presence FIRST — pushes for this chat should resume the moment it
    // is no longer on screen, not two minutes later when the claim goes stale.
    //
    // Through the notifier captured in initState, NEVER through `ref`: see the
    // note on `_push`. And `releaseOpenChat` rather than `setOpenChat(null)`,
    // because on a route swap the NEXT chat has already claimed presence by the
    // time this runs — clearing unconditionally would wipe the chat the staff
    // member is now looking at.
    unawaited(_push.releaseOpenChat(widget.waId));
    // Nothing should keep playing behind a screen nobody is looking at.
    unawaited(_voice.stop());

    _windowTimer?.cancel();
    _stickyHideTimer?.cancel();
    _flashTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _showFab.dispose();
    _fabUnread.dispose();
    _stickyDate.dispose();
    _stickyVisible.dispose();
    _windowTick.dispose();
    _flashId.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Scrolling. Touches no provider except the paging notifier, which is
  // idempotent and re-entrancy guarded.
  // -------------------------------------------------------------------------

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;

    // In a reversed list the OLDEST visible message is near maxScrollExtent.
    if (p.pixels >= p.maxScrollExtent - 800) {
      ref.read(messageHistoryProvider(widget.waId).notifier).loadOlder();
    }

    // ValueNotifier dedupes on ==, so these repaint only on a flip.
    _showFab.value = p.pixels > 240;
    if (p.pixels <= 4) _fabUnread.value = 0;

    final rows = ref.read(chatSnapshotProvider(widget.waId)).rows;
    if (rows.isNotEmpty) {
      _stickyDate.value = rows[_estimateTopIndex(p, rows.length)].timestamp;
      _stickyVisible.value = p.pixels > 40;
      // A timestamp plus ONE armed timer, rather than cancel-and-allocate on
      // every scroll callback — which on a 90Hz fling is ~90 Timer allocations
      // and heap removals per second on the hottest path in the app.
      _lastScrollAt = DateTime.now();
      _armStickyHide(_stickyHold);
    }
  }

  static const _stickyHold = Duration(milliseconds: 900);

  void _armStickyHide(Duration delay) {
    if (_stickyHideTimer?.isActive ?? false) return;
    _stickyHideTimer = Timer(delay, () {
      final idle = DateTime.now().difference(_lastScrollAt);
      if (idle >= _stickyHold) {
        _stickyVisible.value = false;
        return;
      }
      _armStickyHide(_stickyHold - idle);
    });
  }

  /// Which row is at the top of the viewport.
  ///
  /// An ESTIMATE from the average row height, not a measurement. Measuring
  /// would mean an `itemExtentBuilder` and a per-message `TextPainter` height
  /// cache, and the only consumer is a floating day chip — which needs to name
  /// the right *day*, and a day spans many rows. Getting it off by one bubble
  /// is invisible; laying out every row to be exact is not.
  int _estimateTopIndex(ScrollPosition p, int count) {
    if (count == 0) return 0;
    final total = p.maxScrollExtent + p.viewportDimension;
    if (total <= 0) return 0;
    final average = total / count;
    if (average <= 0) return 0;
    final topOffset = p.pixels + p.viewportDimension;
    return (topOffset / average).floor().clamp(0, count - 1);
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _fabUnread.value = 0;
    // 0 IS the bottom in a reversed list.
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _settleAfterSend() {
    if (!_scroll.hasClients) return;
    // Only if the user was already near the newest message; yanking them out of
    // history they are reading is exactly what WhatsApp does not do.
    if (_scroll.position.pixels > 600) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _jumpToMessage(String messageId) {
    if (!_scroll.hasClients) return;
    final snapshot = ref.read(chatSnapshotProvider(widget.waId));
    final index = snapshot.indexOfId(messageId);
    if (index == null) {
      showAknSnack(context, 'Wo message abhi load nahi hua. Upar scroll karein.');
      return;
    }
    final p = _scroll.position;
    final total = p.maxScrollExtent + p.viewportDimension;
    final average = total / math.max(snapshot.rows.length, 1);
    // `animateTo(index * average)` would land the target on the very bottom
    // edge of the viewport; back it off so it settles around the lower third,
    // where the estimate's error still leaves it on screen.
    final target = (index * average - p.viewportDimension * 0.35).clamp(
      0.0,
      p.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );

    // Row heights here run from a 30px one-liner to a 100px bubble with a
    // quoted box and a date chip, so a single average can only ever be an
    // approximation. The flash is what makes that acceptable: it names the
    // message the tap meant, instead of leaving staff to guess which of the
    // bubbles on screen they were sent to.
    _flashId.value = messageId;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1100), () {
      _flashId.value = null;
    });
  }

  // -------------------------------------------------------------------------
  // Read receipts
  // -------------------------------------------------------------------------

  /// Hide our own badge immediately. The callable does the real work, but a
  /// badge that lingers for a round trip after you have opened the chat feels
  /// broken, and `chats/{waId}` is `allow write: if false` so the app cannot
  /// zero `unreadCount` itself.
  void _markLocallyRead() {
    // The watermark MUST come off the same clock as the value it is compared
    // against. `chat_tile.dart` tests it against `lastMessageAt`, a Firestore
    // Timestamp written by the backend; `DateTime.now()` is the handset's
    // clock. On a cheap Android running three minutes fast that suppressed the
    // badge for every message arriving in the next three minutes — no badge, no
    // bold name, nothing.
    final seenUpTo =
        ref.read(bestKnownChatProvider(widget.waId))?.lastMessageAt ??
        _newestTailTimestamp();
    if (seenUpTo == null) return;
    ref.read(locallyReadProvider.notifier).mark(widget.waId, seenUpTo);
  }

  DateTime? _newestTailTimestamp() {
    final tail = ref.read(liveTailProvider(widget.waId)).value;
    if (tail == null || tail.messages.isEmpty) return null;
    return tail.messages.first.timestamp;
  }

  Future<void> _markRead() async {
    // Outside the debounce: the watermark is free, and the debounce exists only
    // to stop the callable being hammered.
    _markLocallyRead();

    if (_marking) return;
    final last = _lastMarkReadAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _marking = true;
    _lastMarkReadAt = DateTime.now();

    try {
      await ref.read(chatActionsProvider).markRead(widget.waId);
    } catch (_) {
      // A read receipt is a nicety, never a blocker. The staff member HAS read
      // the chat whatever Meta thinks.
    } finally {
      _marking = false;
    }
  }

  /// Bump the FAB's counter when something lands while the user is scrolled up.
  void _onTailChanged(
    AsyncValue<LiveTail>? previous,
    AsyncValue<LiveTail> next,
  ) {
    final after = next.value?.messages;
    if (after == null || after.isEmpty) return;

    final known = _knownIds;
    _knownIds = {for (final m in after) m.id};

    if (known == null) {
      // First snapshot for this chat.
      _markLocallyRead();
      return;
    }

    // "Did index 0 change?" is the wrong question. The tail is ordered by
    // `timestamp desc`; Meta stamps inbound messages in WHOLE SECONDS
    // (ids.js::unixSecondsToTimestamp) while our own drafts carry the device
    // clock in milliseconds. A customer message that arrives a beat after a
    // staff reply therefore sorts BELOW it and never becomes the newest row —
    // so markChatRead was never re-sent, the unread badge stayed lit on all
    // four phones while the chat was open on this one, and the customer never
    // got a blue tick. Diff the id set instead.
    var arrived = 0;
    for (final m in after) {
      if (known.contains(m.id)) continue;
      // Reactions are folded onto their parent bubble and filtered out of the
      // rendered list, so counting them would advertise messages that are not
      // there.
      if (m.direction != 'in' || m.isReaction) continue;
      arrived++;
    }
    if (arrived == 0) return;

    _markRead();
    // No auto-scroll, and no PositionRetainedScrollPhysics. The user is looking
    // at the message they are reading; the shift is one bubble height, and
    // yanking the viewport is far more disorienting than absorbing it.
    if (_scroll.hasClients && _scroll.position.pixels > 240) {
      _fabUnread.value = _fabUnread.value + arrived;
    }
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.listen(liveTailProvider(widget.waId), _onTailChanged);
    // Photo previews of this chat download in the background (4/5-Oct-2026).
    ref.watch(thumbPrefetchProvider(widget.waId));

    final known = ref.watch(bestKnownChatProvider(widget.waId));
    final chat = known ?? Chat(waId: widget.waId);

    // Until a document has actually arrived we do not KNOW the window is shut.
    // `Chat()`'s default `windowExpiresAt` is null, which `ReplyWindow.isOpen`
    // reads as closed — so every chat open used to render a locked composer and
    // a "paid template lagega" warning for the first frames, and permanently if
    // the stream errored (chatDocProvider deliberately does not auto-retry).
    // Guessing "closed" on a document we have not read is wrong in both
    // directions; guessing "open" only risks a send the backend will refuse.
    final windowKnown = known != null;
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      // The whole keyboard story. The resize shrinks the list's viewport from
      // the bottom, and `reverse: true` pins scroll offset 0 there, so the
      // newest bubble stays glued above the composer for the entire animation.
      resizeToAvoidBottomInset: true,
      appBar: _ChatAppBar(
        chat: chat,
        windowKnown: windowKnown,
        windowTick: _windowTick,
        onRename: () => showRenameSheet(context, ref, chat),
        onAction: (action) => _handleMenu(action, chat),
      ),
      body: Column(
        children: [
          // ⚠️ ORDER MATTERS. "The bot is quiet, you are in charge" comes
          // FIRST, above "this chat needs a decision" — a staff member who has
          // just taken over needs the reassurance before the task, and the two
          // strips are deliberately different colours so a glance separates
          // them.
          //
          // Wrapped in a ValueListenableBuilder on the same 20-second tick the
          // window countdown already uses, so the strip DISAPPEARS by itself
          // when the pause expires instead of sitting there lying until the
          // next Firestore write.
          RepaintBoundary(
            child: ValueListenableBuilder<DateTime>(
              valueListenable: _windowTick,
              builder: (context, now, _) => chat.botPaused(now)
                  ? BotPausedBanner(
                      chat: chat,
                      tick: _windowTick,
                      onResume: () => _run(
                        () => ref
                            .read(chatActionsProvider)
                            .resumeBot(widget.waId),
                        'Bot dobara chalu',
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          if (chat.needsAttention)
            AttentionBanner(
              reason: chat.attentionReason,
              onDismiss: () => _run(
                () => ref.read(chatActionsProvider).clearAttention(widget.waId),
                'Theek hai',
              ),
            ),
          Expanded(
            child: DecoratedBox(
              decoration: chatWallpaper(brightness),
              child: Stack(
                children: [
                  MessageList(
                    waId: widget.waId,
                    controller: _scroll,
                    onQuotedTap: _jumpToMessage,
                    flashId: _flashId,
                  ),
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: RepaintBoundary(
                      child: StickyDateChip(
                        date: _stickyDate,
                        visible: _stickyVisible,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: RepaintBoundary(
                      child: JumpToBottomFab(
                        visible: _showFab,
                        unread: _fabUnread,
                        onTap: _jumpToBottom,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // `SafeArea(top: false)` is correct here: MediaQuery.padding.bottom
          // becomes 0 while the keyboard is up, so the home-indicator gap
          // collapses exactly when the keyboard already clears it, and comes
          // back when it closes.
          SafeArea(
            top: false,
            child: ValueListenableBuilder<DateTime>(
              valueListenable: _windowTick,
              // The composer is passed as `child` so the 20-second tick swaps
              // between two ALREADY-BUILT subtrees instead of reconstructing
              // the composer — and, with it, the TextField — every tick.
              builder: (context, now, child) =>
                  !windowKnown || chat.window.isOpen(now)
                  ? child!
                  : const WindowClosedBar(),
              child: Composer(waId: widget.waId, onSent: _settleAfterSend),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleMenu(_ChatMenuAction action, Chat chat) async {
    final actions = ref.read(chatActionsProvider);
    switch (action) {
      case _ChatMenuAction.rename:
        await showRenameSheet(context, ref, chat);
      case _ChatMenuAction.pin:
        await _run(
          () => actions.setPinned(widget.waId, !chat.pinned),
          chat.pinned ? 'Pin hata diya' : 'Pin kar diya',
        );
      case _ChatMenuAction.clearAttention:
        await _run(() => actions.clearAttention(widget.waId), 'Theek hai');
      case _ChatMenuAction.copyNumber:
        await Clipboard.setData(ClipboardData(text: widget.waId));
        if (!mounted) return;
        showAknSnack(context, 'Number copy ho gaya');
    }
  }

  Future<void> _run(Future<void> Function() op, String okMessage) async {
    try {
      await op();
      if (!mounted) return;
      showAknSnack(context, okMessage);
    } catch (e) {
      if (!mounted) return;
      showAknSnack(context, describeError(e).message, isError: true);
    }
  }
}

// ---------------------------------------------------------------------------
// App bar
// ---------------------------------------------------------------------------

enum _ChatMenuAction { rename, pin, clearAttention, copyNumber }

class _ChatAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _ChatAppBar({
    required this.chat,
    required this.windowKnown,
    required this.windowTick,
    required this.onRename,
    required this.onAction,
  });

  final Chat chat;

  /// False until a chat document has arrived. The countdown line is simply
  /// omitted rather than asserting the window is shut.
  final bool windowKnown;

  final ValueListenable<DateTime> windowTick;
  final VoidCallback onRename;
  final void Function(_ChatMenuAction) onAction;

  /// The spec asks for the number in the header, but printing it under a title
  /// that IS the number (`displayName` falls back to `prettyPhone`) is just
  /// noise — so the line only appears once the contact has been renamed, which
  /// is exactly when the number is otherwise invisible on this screen.
  bool get _showNumber => chat.hasCustomName;

  /// One fixed height per contact for both window states. The closed label
  /// needs two lines; letting the bar change height as the window shuts would
  /// make the whole screen jump at the exact moment staff are reading it.
  @override
  Size get preferredSize => Size.fromHeight(_showNumber ? 84 : 70);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(numberLabelsProvider);
    final numberLabel = labels.length >= 2 ? labels[chat.phoneNumberId] : null;
    final fallback = chatTitle(chat, ref.watch(partyNamesProvider).value ?? const <String, String>{});
    // Owner, 11-Oct-2026: "iPhone contact name, Business-app saved name,
    // customer's own WhatsApp name" — each once, in that order.
    final phoneBook = ref.watch(phoneContactNamesProvider).value ?? const <String, String>{};
    final names = <String>[];
    for (final n in [phoneBook[last10(chat.customerWaId)], chat.phoneSavedName, chat.profileName]) {
      final t = n?.trim();
      if (t != null && t.isNotEmpty && !names.any((x) => x.toLowerCase() == t.toLowerCase())) names.add(t);
    }
    final title = names.isEmpty ? fallback : names.join(', ');
    return AppBar(
      toolbarHeight: _showNumber ? 84 : 70,
      titleSpacing: 0,
      title: InkWell(
        onTap: onRename,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              AvatarInitials(
                displayName: title,
                waId: chat.customerWaId,
                size: 38,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        if (numberLabel != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              numberLabel,
                              style: const TextStyle(fontSize: 10.5, color: Colors.white),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_showNumber)
                      Text(
                        prettyPhone(chat.customerWaId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.2,
                          color: Colors.white.withValues(alpha: 0.78),
                        ),
                      ),
                    const SizedBox(height: 1),
                    // The countdown lives in its own RepaintBoundary so a tick
                    // repaints two lines of text and nothing else. Without it
                    // the once-every-20-seconds repaint dirties the whole
                    // list's layer — check with debugRepaintRainbowEnabled.
                    RepaintBoundary(
                      child: ValueListenableBuilder<DateTime>(
                        valueListenable: windowTick,
                        builder: (context, now, _) {
                          if (!windowKnown) return const SizedBox(height: 13);
                          final open = chat.window.isOpen(now);
                          return Text(
                            chat.window.label(now),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.15,
                              fontWeight: FontWeight.w500,
                              color: open
                                  ? const Color(0xFF8FF0B4)
                                  : Colors.white.withValues(alpha: 0.72),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        _BotToggle(chat: chat),
        PopupMenuButton<_ChatMenuAction>(
          tooltip: 'Aur options',
          onSelected: onAction,
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _ChatMenuAction.rename,
              child: Text('Naam badlein'),
            ),
            PopupMenuItem(
              value: _ChatMenuAction.pin,
              child: Text(chat.pinned ? 'Pin hataayein' : 'Pin karein'),
            ),
            if (chat.needsAttention)
              const PopupMenuItem(
                value: _ChatMenuAction.clearAttention,
                child: Text('Attention hataayein'),
              ),
            const PopupMenuItem(
              value: _ChatMenuAction.copyNumber,
              child: Text('Number copy karein'),
            ),
          ],
        ),
      ],
    );
  }
}

class _BotToggle extends ConsumerStatefulWidget {
  const _BotToggle({required this.chat});

  final Chat chat;

  @override
  ConsumerState<_BotToggle> createState() => _BotToggleState();
}

class _BotToggleState extends ConsumerState<_BotToggle> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(chatActionsProvider)
          .setBotEnabled(widget.chat.waId, !widget.chat.botEnabled);
      if (!mounted) return;
      showAknSnack(
        context,
        widget.chat.botEnabled ? 'Bot band kar diya' : 'Bot chalu kar diya',
      );
    } catch (e) {
      if (!mounted) return;
      showAknSnack(context, describeError(e).message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ THREE states, not two. `botGlobalEnabled` is the backend's FIRST gate
    // (botReply.js::runTurn, before anything else runs), it ships FALSE, and it
    // is documented to stay false until billing is attached to the Gemini key.
    // A per-chat "on" means nothing while it is off — but this button used to
    // read only `chat.botEnabled`, which defaults to true, so on day one every
    // chat showed a lit gold robot saying "Bot chalu hai". Four staff members
    // conclude the bot is answering that customer and stop watching the chat.
    // Nothing is answering. The Settings screen warns correctly; this is where
    // staff actually live, and it was contradicting it.
    final globallyOn = ref.watch(appSettingsProvider).value?.botGlobalEnabled ?? false;
    final on = widget.chat.botEnabled;
    final effective = on && globallyOn;

    return IconButton(
      onPressed: _busy ? null : _toggle,
      tooltip: !globallyOn
          ? 'Bot globally band hai — Settings me chalu karein'
          : on
          ? 'Bot chalu hai — band karein'
          : 'Bot band hai — chalu karein',
      icon: Icon(
        effective ? Icons.smart_toy : Icons.smart_toy_outlined,
        color: effective
            ? AknColors.goldSoft
            // On for this chat, but globally disarmed: dimmer than a plain
            // "off", so the two are not confused with each other.
            : on
            ? Colors.white38
            : Colors.white70,
      ),
    );
  }
}
