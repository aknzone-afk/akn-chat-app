import 'package:flutter/material.dart';

import '../../../../app/theme.dart';

/// The amber strip.
///
/// The backend raises `needsAttention` when a send fails
/// (`sendMessage.js` → `handleSendError`), when a delivery webhook reports
/// `failed` (`statuses.js` → `applyStatusToMessage`), when a customer
/// changes their WhatsApp number (`ingest.js`), and — Phase 5 — every time the
/// bot decides a human is needed (`botReply.js` → `escalate`). Clearing it is a
/// call to `updateChat({waId, patch: {needsAttention: false}})` — the app
/// cannot write the chat document itself.
///
/// [reason] is `chats/{waId}.attentionReason`, a short Hinglish phrase like
/// "Rate/discount ki baat" or "Design nahi mila: 6540". It matters: the banner
/// used to say only "look at this chat", which does not tell staff what they
/// are looking for — and the "why" is the whole value of the bot's triage.
class AttentionBanner extends StatelessWidget {
  const AttentionBanner({super.key, required this.onDismiss, this.reason});

  final VoidCallback onDismiss;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AknColors.attentionDark : AknColors.attentionLight;
    final ink = isDark ? AknColors.attentionInkDark : AknColors.attentionInk;

    return Material(
      color: bg,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.warning_amber_rounded, size: 17, color: ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                reason == null || reason!.trim().isEmpty
                    ? 'Is chat par dhyaan dein'
                    : 'Dhyaan dein — ${reason!.trim()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ),
            TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: ink,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Theek hai'),
            ),
          ],
        ),
      ),
    );
  }
}
