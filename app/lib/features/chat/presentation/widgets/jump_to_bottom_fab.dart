import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme.dart';

/// "Jump to newest", carrying a count of what arrived while you were reading.
///
/// The count is NOT `chat.unreadCount` — that is zeroed by `markChatRead` the
/// moment the screen opens. This is a purely local tally of inbound messages
/// that landed while the user was scrolled up.
class JumpToBottomFab extends StatelessWidget {
  const JumpToBottomFab({
    super.key,
    required this.visible,
    required this.unread,
    required this.onTap,
  });

  final ValueListenable<bool> visible;
  final ValueListenable<int> unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, show, child) => AnimatedScale(
        scale: show ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutBack,
        child: IgnorePointer(ignoring: !show, child: child),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          FloatingActionButton.small(
            heroTag: 'jumpToBottom',
            onPressed: onTap,
            tooltip: 'Sabse naye message par jaayein',
            child: const Icon(Icons.keyboard_arrow_down, size: 26),
          ),
          Positioned(
            top: -7,
            right: -5,
            child: ValueListenableBuilder<int>(
              valueListenable: unread,
              builder: (context, count, _) => count <= 0
                  ? const SizedBox.shrink()
                  : Container(
                      constraints: const BoxConstraints(minWidth: 19),
                      height: 19,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AknColors.maroon,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AknColors.goldSoft,
                          width: 1.2,
                        ),
                      ),
                      child: Text(
                        count > 99 ? '99+' : '$count',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
