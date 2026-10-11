import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/theme.dart';
import '../../../../core/errors/failure.dart';
import '../../../../core/firebase/firebase_providers.dart';
import '../../../../core/format/formatters.dart';
import '../../../../core/widgets/states.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/chat_actions.dart';
import '../../domain/message.dart';
import '../../providers/chat_providers.dart';
import 'bot_why_sheet.dart';
import 'date_chip.dart';
import 'link_spans.dart';
import 'media/document_tile.dart';
import 'media/image_bubble.dart';
import 'media/sticker_bubble.dart';
import 'media/video_bubble.dart';
import 'media/voice_bubble.dart';
import 'ticks.dart';

/// One list item: an optional date chip, then the bubble.
///
/// The date chip lives INSIDE the item rather than as its own list entry.
/// Separate entries would mean `itemCount`, the index maths and
/// `findChildIndexCallback` all have to account for interleaved non-message
/// rows — a permanent source of off-by-ones.
class MessageRowWidget extends ConsumerStatefulWidget {
  const MessageRowWidget({
    super.key,
    required this.waId,
    required this.row,
    required this.onQuotedTap,
    required this.flashId,
  });

  final String waId;
  final MessageRow row;
  final void Function(String messageId) onQuotedTap;

  /// Which message a quoted-reply tap has just jumped to, if any.
  final ValueListenable<String?> flashId;

  @override
  ConsumerState<MessageRowWidget> createState() => _MessageRowWidgetState();
}

class _MessageRowWidgetState extends ConsumerState<MessageRowWidget> {
  final MenuController _menu = MenuController();

  /// Set by "Text select karein". Swaps this one bubble to a scoped
  /// `SelectionArea`.
  bool _selecting = false;

  Message get _message => widget.row.message;

  void _startReply() {
    ref.read(replyTargetProvider(widget.waId).notifier).set(_message);
  }

  Future<void> _copy() async {
    final text = _message.rendersAsText
        ? _message.body
        : _message.shortPreview;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    // Android 13+ shows its own "Copied" toast. Two confirmations for one tap
    // reads as a bug, and every staff phone here is Android.
    if (Theme.of(context).platform != TargetPlatform.android) {
      showAknSnack(context, 'Copy ho gaya');
    }
  }

  Future<void> _retry() async {
    try {
      await ref
          .read(chatActionsProvider)
          .retry(waId: widget.waId, message: _message);
    } catch (e) {
      if (!mounted) return;
      showAknSnack(context, describeError(e).message, isError: true);
    }
  }

  /// Only the phone whose staff member wrote the draft can actually retry it.
  bool get _canRetry =>
      _message.isRetryableBy(ref.watch(firebaseAuthProvider).currentUser?.uid);

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final message = row.message;
    final isOut = message.isOutgoing;
    final maxWidth = MediaQuery.sizeOf(context).width * Bubbles.maxWidthFactor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (row.showDateChip)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Center(child: DateChip(date: message.timestamp)),
          ),
        _FlashTint(
          flashId: widget.flashId,
          messageId: message.id,
          child: Padding(
            padding: EdgeInsets.only(
              left: isOut ? 52 : 8,
              right: isOut ? 8 : 52,
              top: row.isGroupHead ? Bubbles.groupGap : Bubbles.gap,
              bottom: Bubbles.gap,
            ),
            child: Align(
              alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Column(
                  crossAxisAlignment: isOut
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MenuAnchor(
                      controller: _menu,
                      menuChildren: _menuItems(),
                      builder: (context, controller, child) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPressStart: (details) {
                          // Fires the instant the long-press threshold is
                          // crossed. This one line is most of what makes the
                          // gesture feel native.
                          HapticFeedback.selectionClick();
                          controller.open(position: details.localPosition);
                        },
                        onDoubleTap: _startReply,
                        child: child,
                      ),
                      child: _Bubble(
                        waId: widget.waId,
                        row: row,
                        selecting: _selecting,
                        onQuotedTap: widget.onQuotedTap,
                      ),
                    ),
                    if (row.reactions.isNotEmpty)
                      _ReactionPill(emojis: row.reactions),
                    // Explaining a failure and offering a retry are two
                    // different things. `statuses.js` writes `status: 'failed'`
                    // onto messages that ALREADY have a wamid — a customer who
                    // blocked the number, an undeliverable message — and keeps
                    // Meta's reason in `error`. Gating the strip on
                    // retryability meant that exact case rendered a bare red
                    // "!" with no text at all, and staff retyped the message
                    // into the same block.
                    if (row.tick == Tick.failed)
                      _FailedStrip(
                        reason: _failureReason(message),
                        onRetry: _canRetry ? _retry : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _failureReason(Message m) {
    if (m.localFailure != null) return m.localFailure!;
    final error = m.error;
    if (error != null) {
      final code = error['code'];
      if (code == 'WINDOW_CLOSED') {
        return '24 ghante ka window band tha.';
      }
      // Phase 5. The bot drafted a reply, then found a human had spoken in the
      // meantime and stood down. The draft is deliberately NOT deleted — staff
      // can see the bot TRIED, and a message that silently disappears is what
      // makes an owner distrust the whole system.
      if (code == 'BOT_SUPERSEDED') {
        return 'Bot ne bhejna cancel kiya — staff ne reply kiya.';
      }
      if (code == 'BOT_RATE_LIMITED') {
        return 'Bot ki limit lag gayi — ye reply nahi gaya.';
      }
      final title = error['title'] ?? error['message'];
      if (title is String && title.isNotEmpty) return title;
    }
    if ((m.statusRank ?? 0) == 0) {
      return 'Message atak gaya — dobara bhejein.';
    }
    return 'Message bheja nahi ja saka.';
  }

  List<Widget> _menuItems() {
    final message = _message;
    return [
      MenuItemButton(
        leadingIcon: const Icon(Icons.reply, size: 19),
        onPressed: _startReply,
        child: const Text('Reply karein'),
      ),
      if (message.rendersAsText || message.caption != null)
        MenuItemButton(
          leadingIcon: const Icon(Icons.copy_rounded, size: 19),
          onPressed: _copy,
          child: const Text('Copy karein'),
        ),
      if (message.rendersAsText && !_selecting)
        MenuItemButton(
          leadingIcon: const Icon(Icons.text_fields, size: 19),
          onPressed: () => setState(() => _selecting = true),
          child: const Text('Text select karein'),
        ),
      if (_selecting)
        MenuItemButton(
          leadingIcon: const Icon(Icons.close, size: 19),
          onPressed: () => setState(() => _selecting = false),
          child: const Text('Select band karein'),
        ),
      if (widget.row.tick == Tick.failed && _canRetry)
        MenuItemButton(
          leadingIcon: const Icon(Icons.refresh, size: 19),
          onPressed: _retry,
          child: const Text('Dobara bhejein'),
        ),
      // Phase 5. Every bot bubble is auditable from the bubble itself. The
      // owner of a wholesale firm will not read Firestore; if he cannot ask
      // "why did it say that?" here, the bot is not audited.
      if (message.from == 'bot' && message.botTurnId != null)
        MenuItemButton(
          leadingIcon: const Icon(Icons.help_outline, size: 19),
          onPressed: () => showBotWhySheet(context, message.botTurnId!),
          child: const Text('Ye reply kyun?'),
        ),
    ];
  }
}

/// Tints one row while a quoted-reply jump is pointing at it.
///
/// Fed by a `ValueNotifier` rather than a provider so that flashing a message
/// never rebuilds the list or any bubble's content — only this one wrapper's
/// colour.
class _FlashTint extends StatelessWidget {
  const _FlashTint({
    required this.flashId,
    required this.messageId,
    required this.child,
  });

  final ValueListenable<String?> flashId;
  final String messageId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.primary.withValues(alpha: 0.13);
    return ValueListenableBuilder<String?>(
      valueListenable: flashId,
      child: child,
      builder: (context, id, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        color: id == messageId ? tint : Colors.transparent,
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The bubble itself
// ---------------------------------------------------------------------------

class _Bubble extends ConsumerWidget {
  const _Bubble({
    required this.waId,
    required this.row,
    required this.selecting,
    required this.onQuotedTap,
  });

  final String waId;
  final MessageRow row;
  final bool selecting;
  final void Function(String messageId) onQuotedTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = row.message;
    final brightness = Theme.of(context).brightness;
    final isOut = message.isOutgoing;
    final scaler = MediaQuery.textScalerOf(context);

    // A sticker gets NO bubble. WhatsApp floats them on the wallpaper, and a
    // transparent WebP inside a white rounded rectangle looks broken.
    if (message.type == MsgType.sticker) {
      return Column(
        crossAxisAlignment: isOut
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          StickerBubble(message: message),
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 2),
            child: MetaRow(time: bubbleTime(message.timestamp), tick: row.tick),
          ),
        ],
      );
    }

    final time = bubbleTime(message.timestamp);
    final metaWidth = MetaRowSpec.width(
      time: time,
      tick: row.tick,
      scaler: scaler,
      brightness: brightness,
    );

    // A media message shows its placeholder tile; its caption (if any) is the
    // text that the meta row tucks into. `unknown` counts as text whenever
    // normalize.js kept a readable line on it — see Message.rendersAsText.
    final isText = message.rendersAsText;
    final displayText = isText ? message.body : (message.caption ?? '').trim();

    final radius = BorderRadius.only(
      topLeft: !isOut && row.isGroupHead ? Bubbles.tightRadius : Bubbles.radius,
      topRight: isOut && row.isGroupHead ? Bubbles.tightRadius : Bubbles.radius,
      bottomLeft: Bubbles.radius,
      bottomRight: Bubbles.radius,
    );

    final senderLabel = _senderLabel(ref, message);

    // An image or video with nothing else in the bubble sits almost flush, the
    // way WhatsApp does it, and the time + ticks float on the picture over a
    // soft scrim. Anything else — a caption, a quoted box, a sender label —
    // goes back to the normal text padding so the layout stays honest.
    final bare =
        (message.type == MsgType.image || message.type == MsgType.video) &&
        displayText.isEmpty &&
        message.replyToWamid == null &&
        !message.forwarded &&
        !(row.isGroupHead && senderLabel != null);

    return Container(
      padding: bare ? const EdgeInsets.all(3) : Bubbles.padding,
      decoration: BoxDecoration(
        // A bot message gets a desaturated, slate-shifted green. Close enough
        // that the thread still reads as one conversation; different enough
        // that scrolling it separates machine from human without reading.
        color: isOut
            ? outgoingBubbleColor(brightness, message.from)
            : inBubbleColor(brightness),
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 1.2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Once per RUN, not once per bubble. WhatsApp Business prints the
          // sender on the head of a run; five quick replies in a row each
          // carrying a maroon "Rahul" four pixels apart reads as a bug.
          //
          // ⚠️ EXCEPT for the bot, which is labelled on EVERY bubble. Grouping
          // is a cosmetic nicety; "a machine wrote this, not a person" is not,
          // and a bot reply that lands in the middle of a staff run would
          // otherwise carry no mark at all.
          if ((row.isGroupHead || message.from == 'bot') && senderLabel != null)
            _SenderLabel(name: senderLabel, isBot: message.from == 'bot'),
          if (message.replyToWamid != null)
            _QuotedBox(
              quoted: row.quoted,
              isOut: isOut,
              onTap: row.quoted == null
                  ? null
                  : () => onQuotedTap(row.quoted!.id),
            ),
          if (message.forwarded) const _ForwardedLabel(),
          // The type routing. `location`, `contacts` and `unknown` keep the
          // Phase 3 placeholder tile verbatim — it is correct for them and
          // there is no viewer to send them to.
          if (!isText)
            _media(context, message, displayText.isNotEmpty, bare, time, row),
          if (displayText.isEmpty && !bare)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(top: isText ? 0 : 4),
                child: MetaRow(time: time, tick: row.tick),
              ),
            )
          else if (displayText.isNotEmpty)
            _TextWithTuckedMeta(
              text: displayText,
              time: time,
              tick: row.tick,
              metaWidth: metaWidth,
              selecting: selecting,
              brightness: brightness,
              topPad: isText ? 0 : 5,
            ),
        ],
      ),
    );
  }

  /// The media widget for this type, with the meta row floated on top when the
  /// bubble is a bare picture.
  Widget _media(
    BuildContext context,
    Message message,
    bool hasCaption,
    bool bare,
    String time,
    MessageRow row,
  ) {
    final child = switch (message.type) {
      MsgType.image => ImageBubble(
        waId: waId,
        message: message,
        hasCaption: hasCaption,
      ),
      MsgType.video => VideoBubble(
        waId: waId,
        message: message,
        hasCaption: hasCaption,
      ),
      MsgType.audio => VoiceBubble(message: message),
      MsgType.document => DocumentTile(message: message),
      _ => _MediaPlaceholder(message: message),
    };

    if (!bare) return child;

    return Stack(
      children: [
        child,
        Positioned(
          right: 6,
          bottom: 5,
          child: MetaRow(time: time, tick: row.tick, onDark: true),
        ),
      ],
    );
  }

  String? _senderLabel(WidgetRef ref, Message message) {
    if (!message.isOutgoing) return null;
    // The emoji IS the affordance: it matches the 🤖 the customer sees on the
    // end of every bot message, so staff and customer are reading the same
    // thread with the same marks on it.
    if (message.from == 'bot') return '🤖 AKN bot';
    if (message.from == 'phone') return '📱 WhatsApp Business app';
    final uid = message.senderStaffId;
    if (uid == null) return null;
    // `staff` is `allow list: if false`, so names come from
    // settings/app.staffNames — a map the owner fills in by hand.
    final name = ref.watch(staffNamesProvider)[uid];
    return name;
  }
}

/// Text + the meta row tucked into its last line.
///
/// The trick is the zero-height [WidgetSpan]: the text engine treats it as an
/// inline box, so the paragraph itself decides whether the time and ticks fit
/// on the last line (leaving a hole to paint them into) or push the bubble one
/// line taller. That is exactly WhatsApp's rule — and because the *paragraph*
/// does the line-breaking, it is automatically right for Devanagari, Gujarati,
/// emoji and accessibility text scaling.
///
/// The rejected alternatives, for the record: `IntrinsicWidth` is O(N²)
/// speculative layout per visible bubble per scroll tick (the classic cause of
/// a 40fps chat); a trailing-NBSP hack breaks on any font or locale change; and
/// `Row(mainAxisSize: min)[Flexible(Text), meta]` cannot produce the
/// tucked-into-the-last-line effect at all.
class _TextWithTuckedMeta extends StatefulWidget {
  const _TextWithTuckedMeta({
    required this.text,
    required this.time,
    required this.tick,
    required this.metaWidth,
    required this.selecting,
    required this.brightness,
    required this.topPad,
  });

  final String text;
  final String time;
  final Tick tick;
  final double metaWidth;
  final bool selecting;
  final Brightness brightness;
  final double topPad;

  @override
  State<_TextWithTuckedMeta> createState() => _TextWithTuckedMetaState();
}

class _TextWithTuckedMetaState extends State<_TextWithTuckedMeta> {
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  String get text => widget.text;
  String get time => widget.time;
  Tick get tick => widget.tick;
  double get metaWidth => widget.metaWidth;
  bool get selecting => widget.selecting;
  Brightness get brightness => widget.brightness;
  double get topPad => widget.topPad;

  @override
  Widget build(BuildContext context) {
    final style = bubbleTextStyle(brightness);

    final body = Stack(
      children: [
        Text.rich(
          TextSpan(
            children: [
              ...(() {
                for (final t in _taps) {
                  t.dispose();
                }
                _taps.clear();
                return linkSpans(context, text, _taps);
              })(),
              WidgetSpan(
                child: SizedBox(width: metaWidth + 4, height: 1),
              ),
            ],
          ),
          style: style,
          // Without this the paragraph takes `maxIntrinsicWidth` clamped to the
          // incoming constraint — so EVERY bubble that wraps is exactly 78% of
          // the screen with a ragged right edge, and `Positioned(right: 0)`
          // parks the clock at that far edge instead of in the hole the
          // WidgetSpan reserved (measured: ~18px adrift of the last word).
          // `longestLine` sizes the paragraph to its widest line, which is what
          // makes the bubble hug its text and the meta row tuck in.
          textWidthBasis: TextWidthBasis.longestLine,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: MetaRow(time: time, tick: tick),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(top: topPad),
      child: selecting
          // Scoped to this one bubble. A `SelectionArea` around the whole list
          // would make long-press start a selection drag, which fights the
          // action menu — that is the mistake this design exists to avoid.
          ? SelectionArea(
              child: Text(
                text,
                style: style,
                textWidthBasis: TextWidthBasis.longestLine,
              ),
            )
          : body,
    );
  }
}

// ---------------------------------------------------------------------------
// Trimmings
// ---------------------------------------------------------------------------

class _SenderLabel extends StatelessWidget {
  const _SenderLabel({required this.name, this.isBot = false});

  final String name;
  final bool isBot;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        name,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          // The bot's own accent, not the neutral staff-name grey and not the
          // maroon either — so "who said this" is answerable at a glance.
          color: isBot
              ? (isDark ? AknColors.botPausedInkDark : AknColors.botPausedInk)
              : Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _ForwardedLabel extends StatelessWidget {
  const _ForwardedLabel();

  @override
  Widget build(BuildContext context) {
    final color = metaTextStyle(Theme.of(context).brightness).color;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.reply, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            'Forwarded',
            style: TextStyle(
              fontSize: 11.5,
              fontStyle: FontStyle.italic,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// The quoted box above a reply.
class _QuotedBox extends StatelessWidget {
  const _QuotedBox({required this.quoted, required this.isOut, this.onTap});

  final Message? quoted;
  final bool isOut;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = quoted != null && quoted!.isOutgoing
        ? const Color(0xFF25D366)
        : AknColors.gold;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(5),
            border: Border(left: BorderSide(color: accent, width: 3.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                quoted == null
                    ? 'Message'
                    : (quoted!.isOutgoing ? 'Aap' : 'Customer'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                quoted?.shortPreview ??
                    'Purana message — upar scroll karke dekhein',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  color: metaTextStyle(Theme.of(context).brightness).color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The stand-in tile, kept for the three types that still have no viewer:
/// `location`, `contacts` and `unknown`. Photos, videos, documents, voice notes
/// and stickers all render for real since Phase 4 and never reach here.
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.message});

  final Message message;

  IconData get _icon => switch (message.type) {
    MsgType.image => Icons.photo_outlined,
    MsgType.video => Icons.videocam_outlined,
    MsgType.document => Icons.description_outlined,
    MsgType.audio => message.voice ? Icons.mic_none : Icons.audiotrack_outlined,
    MsgType.sticker => Icons.emoji_emotions_outlined,
    MsgType.location => Icons.place_outlined,
    MsgType.contacts => Icons.person_outline,
    _ => Icons.help_outline,
  };

  String get _title => switch (message.type) {
    MsgType.image => 'Photo',
    MsgType.video => 'Video',
    MsgType.document => message.fileName ?? 'Document',
    MsgType.audio => message.voice ? 'Voice message' : 'Audio',
    MsgType.sticker => 'Sticker',
    MsgType.location => message.locationName ?? 'Location',
    MsgType.contacts => message.contactName ?? 'Contact card',
    _ => 'WhatsApp ne ye message nahi bheja',
  };

  /// Only ever reached for `location`, `contacts` and `unknown` now, so there
  /// is no media status to report — `mediaStatusLabel` in
  /// media/media_status_overlay.dart is the single interpreter of those seven
  /// states, and nothing here duplicates it.
  String get _subtitle => switch (message.type) {
    MsgType.location => 'Map app me kholein',
    MsgType.contacts => message.tapUrl != null ? 'Tap karke call karein' : 'Contact card',
    // Meta delivers polls, view-once media, events etc. as "unsupported".
    _ => 'Poll / view-once — customer ke WhatsApp me hi dikhega',
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final metaColor = metaTextStyle(Theme.of(context).brightness).color;

    final url = message.tapUrl;
    final tile = Container(
      constraints: const BoxConstraints(minWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(_icon, size: 19, color: metaColor),
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: bubbleTextStyle(
                    Theme.of(context).brightness,
                  ).copyWith(fontSize: 14.5, fontWeight: FontWeight.w500),
                ),
                if (_subtitle.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: metaColor),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (url == null) return tile;
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: tile,
    );
  }
}

class _ReactionPill extends StatelessWidget {
  const _ReactionPill({required this.emojis});

  final List<String> emojis;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Transform.translate(
      offset: const Offset(0, -6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF22303A) : Colors.white,
          borderRadius: BorderRadius.circular(11),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          emojis.take(3).join(),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }
}

/// The red line under a failed bubble.
///
/// [onRetry] is null when the failure is not this phone's to fix — Meta already
/// has the message, or another staff member wrote the draft. In that case the
/// reason is still shown (it is the only explanation staff will ever get) but
/// nothing is offered to tap, because the backend would refuse it.
class _FailedStrip extends StatelessWidget {
  const _FailedStrip({required this.reason, this.onRetry});

  final String reason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 13, color: AknColors.tickRed),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            reason,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: AknColors.tickRed),
          ),
        ),
        if (onRetry != null) ...[
          const SizedBox(width: 6),
          const Text(
            'Dobara bhejein',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AknColors.tickRed,
              decoration: TextDecoration.underline,
              decorationColor: AknColors.tickRed,
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 3, right: 2),
      child: onRetry == null
          ? row
          : GestureDetector(
              onTap: onRetry,
              behavior: HitTestBehavior.opaque,
              child: row,
            ),
    );
  }
}
