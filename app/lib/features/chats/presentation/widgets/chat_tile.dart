import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../../../core/format/formatters.dart';
import '../../../../core/widgets/avatar_initials.dart';
import '../../domain/chat.dart';

/// One row of the home screen. Deliberately a plain `StatelessWidget` reading
/// only the [Chat] it was handed — nothing here watches a provider, so a
/// message arriving in one chat repaints one tile.
class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.chat,
    required this.now,
    required this.locallyRead,
    required this.onTap,
    this.onLongPress,
    this.numberLabel,
    this.title,
    this.onTapDown,
  });

  final Chat chat;

  /// Passed in rather than read from `DateTime.now()` inside `build`, so every
  /// tile in one frame agrees about what "today" means.
  final DateTime now;

  /// This phone has opened the chat; the badge is suppressed until something
  /// newer than that arrives.
  final bool locallyRead;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Which of our business numbers this chat is on — null with only one number.
  final String? numberLabel;

  /// The name to show (staff name → Tally party name → profile/number).
  final String? title;

  /// Fires the moment a finger lands, so the chat's messages start loading
  /// before the tap completes and the screen is pushed.
  final VoidCallback? onTapDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final windowOpen = chat.window.isOpen(now);
    final unread = locallyRead ? 0 : chat.unreadCount;
    final hasUnread = unread > 0;

    final attentionInk = theme.brightness == Brightness.dark
        ? AknColors.attentionInkDark
        : AknColors.attentionInk;

    final name = title ?? chat.displayName;
    return InkWell(
      onTap: onTap,
      onTapDown: onTapDown == null ? null : (_) => onTapDown!(),
      onLongPress: onLongPress,
      child: Container(
        // A 3px amber edge, so a chat the bot escalated is findable while
        // scrolling a list of sixty. The icon alone sits too far in.
        decoration: chat.needsAttention
            ? BoxDecoration(
                border: Border(left: BorderSide(color: attentionInk, width: 3)),
              )
            : null,
        padding: EdgeInsets.fromLTRB(chat.needsAttention ? 11 : 14, 9, 12, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AvatarInitials(
                  displayName: name,
                  waId: chat.customerWaId,
                  size: 50,
                ),
                // The 24-hour window at a glance. Green = free to reply,
                // grey = a reply would need a paid template.
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: windowOpen
                          ? AknColors.windowOpen
                          : AknColors.windowClosed,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 2.2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (chat.pinned) ...[
                        Icon(
                          Icons.push_pin,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: hasUnread
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      if (numberLabel != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            numberLabel!,
                            style: TextStyle(fontSize: 10.5, color: scheme.onSecondaryContainer),
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        chat.lastMessageAt == null
                            ? ''
                            : chatListTime(chat.lastMessageAt!, now),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w400,
                          color: hasUnread
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (chat.needsAttention) ...[
                        Icon(
                          Icons.error,
                          size: 15,
                          // AttentionBanner and the Settings read-only notice
                          // both lift the amber for dark mode; at 15px on the
                          // dark surface the light-mode ink lands on the WCAG
                          // non-text floor and reads dimmer than every sibling.
                          color: attentionInk,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          _preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.8,
                            color: hasUnread
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            fontWeight: hasUnread
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Two different bot states, two different glyphs.
                      //
                      //   crossed-out toy  = botEnabled == false, the permanent
                      //                      per-chat off switch.
                      //   plain toy        = botPausedUntil in the future, i.e.
                      //                      a staff member has taken this
                      //                      conversation over.
                      //
                      // Staff need "which conversations am I handling myself
                      // right now?" answerable from the chat list, without
                      // opening anything.
                      if (!chat.botEnabled)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.smart_toy_outlined,
                            size: 15,
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                          ),
                        )
                      else if (chat.botPaused(now))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.pause_circle_outline,
                            size: 15,
                            color: theme.brightness == Brightness.dark
                                ? AknColors.botPausedInkDark
                                : AknColors.botPausedInk,
                          ),
                        ),
                      if (hasUnread) _UnreadBadge(count: unread),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _preview {
    // Phase 5. When the bot has pulled a human in, the reason is far more
    // useful than the preview line — "Rate/discount ki baat" tells a staff
    // member what they are opening the chat FOR, which is the entire value of
    // the triage. The message itself is one tap away.
    if (chat.needsAttention) {
      final reason = chat.attentionReason?.trim();
      if (reason != null && reason.isNotEmpty) return reason;
    }
    final text = chat.lastMessageText?.trim();
    if (text == null || text.isEmpty) {
      return chat.lastMessageAt == null ? 'Abhi koi message nahi' : '';
    }
    final icon = chat.previewIcon;
    // ingest.js already prefixes some previews (📍 Location, 👤 Contact), so
    // do not double it up.
    if (icon == null || text.startsWith(icon)) return text;
    return '$icon  $text';
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 21),
    height: 21,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: AknColors.windowOpen,
      borderRadius: BorderRadius.all(Radius.circular(11)),
    ),
    child: Text(
      count > 99 ? '99+' : '$count',
      style: const TextStyle(
        color: Color(0xFF0A2B18),
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
