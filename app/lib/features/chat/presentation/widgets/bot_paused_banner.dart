import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../../../core/format/formatters.dart';
import '../../../chats/domain/chat.dart';

/// "Bot band hai — staff reply kar raha hai."
///
/// The single most important thing staff can know about a chat they have just
/// answered in: the bot is not about to talk over them. `sendMessage.js` sets
/// `botPausedUntil = now + settings.botPauseMinutes` inside the same
/// transaction that claims the draft — before the message even reaches Meta —
/// and refreshes it on every further staff send.
///
/// Slate-blue, not amber: it sits directly above [AttentionBanner] and the two
/// must never be mistaken for each other. This one is reassurance; that one is
/// a job to do.
///
/// The countdown rides the chat screen's EXISTING 20-second `_windowTick`
/// notifier, so it costs no new `Timer` and no rebuild of the message list.
class BotPausedBanner extends StatelessWidget {
  const BotPausedBanner({
    super.key,
    required this.chat,
    required this.tick,
    required this.onResume,
  });

  final Chat chat;
  final ValueListenable<DateTime> tick;

  /// Turn the bot back on now. One `updateChat` call with
  /// `patch: {botPausedUntil: null}` — the app cannot write the chat document.
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AknColors.botPausedDark : AknColors.botPausedLight;
    final ink = isDark ? AknColors.botPausedInkDark : AknColors.botPausedInk;

    return Material(
      color: bg,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.smart_toy_outlined, size: 17, color: ink),
            const SizedBox(width: 8),
            Expanded(
              // Only this text repaints on a tick — the icon, the button and
              // everything below are outside the builder.
              child: RepaintBoundary(
                child: ValueListenableBuilder<DateTime>(
                  valueListenable: tick,
                  builder: (context, now, _) {
                    final left = chat.botPauseRemaining(now);
                    return Text(
                      left == Duration.zero
                          ? 'Bot band hai — staff reply kar raha hai'
                          : 'Bot band hai — staff reply kar raha hai · '
                                '${humanDuration(left)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    );
                  },
                ),
              ),
            ),
            TextButton(
              onPressed: onResume,
              style: TextButton.styleFrom(
                foregroundColor: ink,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Bot chalu karein'),
            ),
          ],
        ),
      ),
    );
  }
}
