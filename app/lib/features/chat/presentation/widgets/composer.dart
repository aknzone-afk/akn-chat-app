import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme.dart';
import '../../../../core/errors/failure.dart';
import '../../../../core/media/media_limits.dart';
import '../../../../core/prefs/prefs.dart';
import '../../../../core/widgets/states.dart';
import '../../data/chat_actions.dart';
import '../../domain/message.dart';
import '../../presentation/media/attach_sheet.dart';
import '../../presentation/media/caption_screen.dart';
import '../../providers/chat_providers.dart';
import 'quick_replies_sheet.dart';

/// Mirrors firestore.rules:95 — `d.text.size() <= 4096`.
///
/// Enforcing it in the field means the rule can never reject a send for length,
/// which would surface to staff as a message that silently refuses to go with
/// nothing to diagnose.
const int kMaxMessageLength = 4096;

class Composer extends ConsumerStatefulWidget {
  const Composer({super.key, required this.waId, required this.onSent});

  final String waId;

  /// Lets the screen settle the list at the bottom if the user was near it.
  final VoidCallback onSent;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  /// The ONLY thing that crosses from the composer into the widget tree, and it
  /// is a bool, so it dedupes on `==` and notifies only when emptiness flips.
  ///
  /// This is the single most common chat performance bug: put the draft text in
  /// the shared store and every keystroke rebuilds every visible bubble.
  final _canSend = ValueNotifier<bool>(false);

  /// Captured while the widget is still mounted, and that is not a style
  /// preference.
  ///
  /// `ref` on a `ConsumerState` is backed by the Element's BuildContext, and
  /// `ConsumerStatefulElement.read()` asserts `context.mounted` first.
  /// `StatefulElement.unmount()` calls `super.unmount()` — which sets
  /// `_widget = null`, so `mounted` is already false — BEFORE `state.dispose()`
  /// runs. So `ref.read(...)` inside `dispose()` throws every single time, the
  /// throw aborts the rest of `_InactiveElements._unmountAll`, and with it the
  /// ChatScreen's own `dispose()`: its 20-second timer keeps firing and its
  /// Firestore listeners never auto-dispose. Holding the notifier in a field is
  /// exactly what Riverpod's own error text tells you to do.
  late final DraftsController _drafts;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(draftsProvider.notifier);
    _text.text = _drafts.read(widget.waId) ?? '';
    _canSend.value = _text.text.trim().isNotEmpty;
    _text.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    _canSend.value = _text.text.trim().isNotEmpty;
  }

  @override
  void dispose() {
    // The draft reaches shared state exactly once, here — through the notifier
    // captured in initState, never through `ref`.
    _drafts.save(widget.waId, _text.text);
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _canSend.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// NOT async. There is not a single `await` before the state mutation, so the
  /// bubble is on screen at the very next vsync.
  void _send() {
    final body = _text.text.trim();
    if (body.isEmpty) return;

    // The header countdown only reprints every 20 seconds (chat_screen.dart's
    // `_windowTickPeriod`), so the composer can still be on screen for up to
    // 20s after the window has actually shut. If the draft goes out now,
    // firestore.rules accepts it, sendMessage.js writes `statusRank: 99` —
    // terminal by design — and `allow update, delete: if false` means neither
    // this app nor any other phone can ever clear it. A permanent red "!" is
    // the exact outcome the gate exists to prevent, so re-check the real clock
    // at the moment of the tap.
    final chat = ref.read(bestKnownChatProvider(widget.waId));
    if (chat != null && !chat.window.isOpen(DateTime.now())) {
      showAknSnack(
        context,
        '24 ghante ka free window abhi band ho gaya. '
        'Customer ke message ka intezaar karein.',
        isError: true,
      );
      return;
    }

    final reply = _resolveReplyWamid();
    if (!reply.ok) {
      showAknSnack(
        context,
        'Jis message ka reply de rahe hain wo abhi WhatsApp tak nahi pahuncha. '
        'Ek pal ruk kar dobara bhejein.',
        isError: true,
      );
      return;
    }
    final replyTo = reply.wamid;

    _text.clear(); // synchronous — the field empties this frame
    ref.read(replyTargetProvider(widget.waId).notifier).clear();
    _drafts.save(widget.waId, '');

    try {
      ref.read(chatActionsProvider).sendText(
        waId: widget.waId,
        body: body,
        replyToWamid: replyTo,
      );
    } on AppFailure catch (f) {
      _text.text = body; // give it back rather than losing what they typed
      showAknSnack(context, f.message, isError: true);
      return;
    }

    widget.onSent();
  }

  /// A reply is quoted by `replyToWamid`, and a message only has a wamid once
  /// the backend has actually put it on WhatsApp. `replyTargetProvider` holds
  /// the Message as it looked when staff long-pressed it, which for their own
  /// just-sent bubble is a second before the wamid landed — so re-read the live
  /// row before giving up. Sending with a silently-dropped quote is worse than
  /// asking staff to tap send again a moment later.
  ({bool ok, String? wamid}) _resolveReplyWamid() {
    final target = ref.read(replyTargetProvider(widget.waId));
    if (target == null) return (ok: true, wamid: null);
    if (target.wamid != null) return (ok: true, wamid: target.wamid);

    final snapshot = ref.read(chatSnapshotProvider(widget.waId));
    final index = snapshot.indexOfId(target.id);
    final fresh = index == null ? null : snapshot.rows[index].message.wamid;
    return fresh == null ? (ok: false, wamid: null) : (ok: true, wamid: fresh);
  }

  /// Pick → caption → send.
  ///
  /// The window is re-checked at the moment of the SEND tap, not when the sheet
  /// opens: chat_screen.dart's countdown only reprints every 20 seconds, and
  /// the caption screen can easily be open across the boundary. A draft written
  /// after the window shuts gets `statusRank: 99` from sendMessage.js — which
  /// is terminal by design, and `allow update, delete: if false` means neither
  /// this phone nor any other can ever clear it.
  Future<void> _attach() async {
    final actions = ref.read(chatActionsProvider);
    final phoneNumberId = actions.resolvePhoneNumberId(widget.waId);
    if (phoneNumberId == null) {
      showAknSnack(context, MediaMessages.chatNotReady, isError: true);
      return;
    }

    final picked = await showAttachSheet(context);
    if (!mounted || picked == null || picked.isEmpty) return;

    final chat = ref.read(bestKnownChatProvider(widget.waId));
    final items = await showCaptionScreen(
      context,
      items: picked,
      contactName: chat?.displayName ?? 'Customer',
    );
    if (!mounted || items == null || items.isEmpty) return;

    if (chat != null && !chat.window.isOpen(DateTime.now())) {
      showAknSnack(
        context,
        '24 ghante ka free window abhi band ho gaya. '
        'Customer ke message ka intezaar karein.',
        isError: true,
      );
      return;
    }

    final reply = _resolveReplyWamid();
    ref.read(replyTargetProvider(widget.waId).notifier).clear();

    try {
      actions.sendMedia(
        waId: widget.waId,
        phoneNumberId: phoneNumberId,
        items: items,
        replyToWamid: reply.ok ? reply.wamid : null,
      );
    } on AppFailure catch (f) {
      showAknSnack(context, f.message, isError: true);
      return;
    }

    widget.onSent();
  }

  void _insertQuickReply(String reply) {
    final selection = _text.selection;
    final text = _text.text;
    // Insert at the cursor; never replace what staff have already typed.
    final at = selection.isValid ? selection.start : text.length;
    final needsSpaceBefore =
        at > 0 && text.isNotEmpty && !text.substring(0, at).endsWith(' ');
    final insert = (needsSpaceBefore ? ' ' : '') + reply;
    final next = text.replaceRange(
      at,
      selection.isValid ? selection.end : text.length,
      insert,
    );
    final capped = next.length > kMaxMessageLength
        ? next.substring(0, kMaxMessageLength)
        : next;
    _text.value = TextEditingValue(
      text: capped,
      // Clamp to the string actually being written, not the untruncated one —
      // otherwise a near-4096-character draft leaves the caret past the end and
      // the platform text input is handed an out-of-range selection.
      selection: TextSelection.collapsed(
        offset: (at + insert.length).clamp(0, capped.length),
      ),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Focus on the TRANSITION into a reply, never on the state of being in one.
    // `_ChatScreenState.build` watches the chat document, and `Chat ==` includes
    // `lastMessageAt`/`lastMessageText`/`unreadCount`, so every incoming message
    // rebuilds this composer. A plain `if (replyTarget != null && !hasFocus)`
    // side effect in build therefore re-opens the keyboard every time a message
    // lands — including right after `keyboardDismissBehavior: onDrag` closed it
    // because staff were scrolling back through the conversation.
    ref.listen<Message?>(replyTargetProvider(widget.waId), (previous, next) {
      if (next != null && previous == null) _focus.requestFocus();
    });
    final replyTarget = ref.watch(replyTargetProvider(widget.waId));

    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyTarget != null)
            _ReplyPreviewBar(
              target: replyTarget,
              onClose: () =>
                  ref.read(replyTargetProvider(widget.waId).notifier).clear(),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.7),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          focusNode: _focus,
                          minLines: 1,
                          // Grow to five lines, then scroll inside — WhatsApp's
                          // behaviour, for free.
                          maxLines: 5,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: kMaxMessageLength,
                          maxLengthEnforcement: MaxLengthEnforcement.enforced,
                          buildCounter:
                              (
                                context, {
                                required currentLength,
                                required isFocused,
                                maxLength,
                              }) => currentLength > 3800
                              ? Text(
                                  '${kMaxMessageLength - currentLength}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                          decoration: const InputDecoration(
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            hintText: 'Message likhein',
                            contentPadding: EdgeInsets.fromLTRB(14, 11, 6, 11),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.bolt_outlined, size: 21),
                        tooltip: 'Quick replies',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          final picked = await showQuickRepliesSheet(context, ref);
                          // The 20-second window tick can swap this composer
                          // for WindowClosedBar while the sheet is open, and
                          // _insertQuickReply touches a disposed controller.
                          if (!mounted || picked == null) return;
                          _insertQuickReply(picked);
                        },
                      ),
                      // No window check on the BUTTON: when the 24-hour window
                      // shuts, chat_screen.dart swaps this whole composer for
                      // WindowClosedBar. The check that matters is the one in
                      // _attach(), at the moment of the send tap.
                      IconButton(
                        icon: const Icon(Icons.attach_file, size: 20),
                        tooltip: 'Photo ya file bhejein',
                        visualDensity: VisualDensity.compact,
                        onPressed: _attach,
                      ),
                      const SizedBox(width: 2),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ValueListenableBuilder<bool>(
                valueListenable: _canSend,
                builder: (context, canSend, _) => _SendButton(
                  enabled: canSend,
                  onTap: _send,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: enabled ? 1 : 0.88,
      duration: const Duration(milliseconds: 120),
      child: Material(
        color: enabled
            ? scheme.primary
            : scheme.surfaceContainerHighest.withValues(alpha: 0.8),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 46,
            height: 46,
            child: Icon(
              Icons.send_rounded,
              size: 20,
              color: enabled
                  ? scheme.onPrimary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyPreviewBar extends StatelessWidget {
  const _ReplyPreviewBar({required this.target, required this.onClose});

  final Message target;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = target.isOutgoing ? const Color(0xFF25D366) : AknColors.gold;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(9),
        border: Border(left: BorderSide(color: accent, width: 3.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  target.isOutgoing ? 'Aapko reply' : 'Customer ko reply',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  target.shortPreview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            tooltip: 'Reply hataayein',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the composer once the 24-hour window has shut.
///
/// Deliberately the SAME height as the composer, so nothing on screen jumps at
/// the transition — and deliberately with no input affordance at all.
///
/// This is a gate, not a warning. firestore.rules would happily accept the
/// draft; `sendMessage.js` would then write `statusRank: 99`, which is terminal
/// by design, and `allow update, delete: if false` means the app could never
/// clean it up. A permanent red "!" for a message the customer was never going
/// to receive is worse than a locked composer, so the document is never written.
class WindowClosedBar extends StatelessWidget {
  const WindowClosedBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '24 ghante ka free window band ho gaya. Jab tak customer '
                'dobara message nahi karta, reply nahi ja sakta.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
