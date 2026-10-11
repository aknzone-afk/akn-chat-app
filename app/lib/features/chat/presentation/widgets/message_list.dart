import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// `ScrollCacheExtent` lives in the rendering layer and is not re-exported by
// material.dart.
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/states.dart';
import '../../providers/chat_providers.dart';
import 'chat_skeleton.dart';
import 'message_bubble.dart';

/// The conversation.
///
/// `reverse: true` is non-negotiable, and not for cosmetic reasons:
///
///  * `scrollOffset == 0` is the BOTTOM, and it is a fixed anchor. Fewer than a
///    screen of messages bottom-align with no `shrinkWrap`, no `Spacer`.
///  * The keyboard shrinks the viewport from the bottom while offset 0 stays
///    pinned there, so the newest bubble stays glued above the composer for the
///    entire keyboard animation — with zero scroll code. Every "scroll to
///    bottom when the keyboard opens" snippet on the internet is a workaround
///    for *not* using `reverse: true`.
///  * Appending older messages (higher indices) lays them out above the visible
///    region. `maxScrollExtent` grows, `pixels` does not, nothing shifts.
///    Pagination is free.
class MessageList extends ConsumerWidget {
  const MessageList({
    super.key,
    required this.waId,
    required this.controller,
    required this.onQuotedTap,
    required this.flashId,
  });

  final String waId;
  final ScrollController controller;
  final void Function(String messageId) onQuotedTap;

  /// The message a quoted-reply tap jumped to; briefly tinted so staff can see
  /// which bubble was meant.
  final ValueListenable<String?> flashId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(chatSnapshotProvider(waId));

    // Never shimmer over data we already have.
    if (snapshot.rows.isNotEmpty) {
      return _List(
        waId: waId,
        controller: controller,
        snapshot: snapshot,
        onQuotedTap: onQuotedTap,
        flashId: flashId,
      );
    }
    if (snapshot.loading) return const _DelayedChatSkeleton();
    if (snapshot.error != null) {
      return ErrorView(
        error: snapshot.error!,
        onRetry: () => ref.invalidate(liveTailProvider(waId)),
      );
    }
    return const EmptyView(
      icon: Icons.waving_hand_outlined,
      title: 'Yahan abhi kuch nahi',
      subtitle: 'Is chat me abhi tak koi message nahi hai.',
    );
  }
}

/// The skeleton, held back until the wait is long enough to be worth
/// explaining.
///
/// `liveTailProvider` is autoDispose, so opening a chat always begins at
/// `AsyncLoading` and the first cached snapshot still has to cross the platform
/// channel. Shimmering for 40ms in the middle of the push transition is a
/// flicker, not a loading state — and it lands exactly where the eye is. Let
/// the wallpaper stand instead.
class _DelayedChatSkeleton extends StatefulWidget {
  const _DelayedChatSkeleton();

  @override
  State<_DelayedChatSkeleton> createState() => _DelayedChatSkeletonState();
}

class _DelayedChatSkeletonState extends State<_DelayedChatSkeleton> {
  static const _delay = Duration(milliseconds: 220);

  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _show ? const ChatSkeleton() : const SizedBox.expand();
}

class _List extends StatelessWidget {
  const _List({
    required this.waId,
    required this.controller,
    required this.snapshot,
    required this.onQuotedTap,
    required this.flashId,
  });

  final String waId;
  final ScrollController controller;
  final ChatSnapshot snapshot;
  final void Function(String messageId) onQuotedTap;
  final ValueListenable<String?> flashId;

  @override
  Widget build(BuildContext context) {
    final rows = snapshot.rows;
    final showFooter = snapshot.hasMore || snapshot.loadingOlder;

    return ListView.builder(
      controller: controller,
      reverse: true,
      // 3.44: `cacheExtent` is deprecated. About a screen and a half of
      // pre-built bubbles, which is what smooths a fling.
      scrollCacheExtent: const ScrollCacheExtent.viewport(1.5),
      // Bubbles are cheap and stateless; keeping them alive off-screen would
      // just burn Elements. Flip this only when a bubble hosts a real player.
      addAutomaticKeepAlives: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      itemCount: rows.length + (showFooter ? 1 : 0),
      // The bit everyone skips, and then wonders why prepends jank. When a new
      // message lands at index 0 every existing index shifts by one; without
      // this, the delegate cannot match the old Element for ValueKey('…') to
      // its new index and tears down and rebuilds the subtree.
      //
      // NOTE: the 3.44 rename to `findItemIndexCallback` applies to
      // `ListView.separated` ONLY. This is `ListView.builder`, so the parameter
      // keeps its name and takes CHILD indices — no `* 2`.
      findChildIndexCallback: (key) =>
          snapshot.indexOfId((key as ValueKey<String>).value),
      itemBuilder: (context, i) {
        if (i >= rows.length) {
          return _HistoryFooter(loading: snapshot.loadingOlder);
        }
        final row = rows[i];
        return MessageRowWidget(
          key: ValueKey(row.id),
          waId: waId,
          row: row,
          onQuotedTap: onQuotedTap,
          flashId: flashId,
        );
      },
    );
  }
}

class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    // Collapses to nothing when idle. In a reversed list this sits at the very
    // TOP of the conversation, so a permanently reserved 50px would read as a
    // gap above the oldest message.
    if (!loading) return const SizedBox(height: 4);
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
