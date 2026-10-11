import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../domain/message.dart';

/// The delivery tick.
///
///   sending   ⏱ clock
///   sent      ✓
///   delivered ✓✓
///   read      ✓✓ blue
///   played    ✓✓ blue (voice notes)
///   failed    ! red, and tappable
///
/// Drawn with `Icons.done` / `Icons.done_all` at a fixed 15 logical pixels so
/// [MetaRowSpec] can predict its width without laying it out.
class TickIcon extends StatelessWidget {
  const TickIcon({super.key, required this.tick, this.onDark = false});

  final Tick tick;

  /// True when the row floats on a photo instead of sitting on a bubble. Grey
  /// on a pale saree is unreadable, so everything goes white except the
  /// read/played blue and the failure red, which carry meaning.
  final bool onDark;

  static const double width = 16;

  Color get _grey => onDark ? Colors.white : AknColors.tickGrey;

  @override
  Widget build(BuildContext context) => switch (tick) {
    Tick.none => const SizedBox.shrink(),
    Tick.sending => Icon(Icons.schedule, size: 13, color: _grey),
    Tick.sent => Icon(Icons.done, size: 15, color: _grey),
    Tick.delivered => Icon(Icons.done_all, size: 15, color: _grey),
    Tick.read || Tick.played => Icon(
      Icons.done_all,
      size: 15,
      color: onDark ? const Color(0xFF8FE3FF) : AknColors.tickBlue,
    ),
    Tick.failed => const Icon(
      Icons.error_outline,
      size: 14,
      color: AknColors.tickRed,
    ),
  };
}

/// The time-and-tick row that gets tucked into the bubble's last line — or, for
/// a caption-less photo, floated on the picture itself.
class MetaRow extends StatelessWidget {
  const MetaRow({
    super.key,
    required this.time,
    required this.tick,
    this.onDark = false,
  });

  final String time;
  final Tick tick;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final base = metaTextStyle(Theme.of(context).brightness);
    final style = onDark
        ? base.copyWith(
            color: Colors.white,
            shadows: const [Shadow(color: Color(0x99000000), blurRadius: 3)],
          )
        : base;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          time,
          style: tick == Tick.failed && !onDark
              ? style.copyWith(color: AknColors.tickRed)
              : style,
        ),
        if (tick != Tick.none) ...[
          const SizedBox(width: 3),
          TickIcon(tick: tick, onDark: onDark),
        ],
      ],
    );
  }
}

/// How wide the meta row will be, so the bubble can reserve exactly that much
/// space with a `WidgetSpan` and let the text engine do the line-breaking.
///
/// There are only a handful of distinct answers — one per (time string, tick,
/// text scale) — so they are measured once and memoised. Measuring per bubble
/// per frame would be a `TextPainter.layout()` on every visible row on every
/// scroll tick.
abstract final class MetaRowSpec {
  static final Map<String, double> _cache = <String, double>{};

  static double width({
    required String time,
    required Tick tick,
    required TextScaler scaler,
    required Brightness brightness,
  }) {
    final scaled = scaler.scale(11).toStringAsFixed(1);
    final key = '$time|${tick.index}|$scaled';
    final cached = _cache[key];
    if (cached != null) return cached;

    final painter = TextPainter(
      text: TextSpan(text: time, style: metaTextStyle(brightness)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final w = painter.width + (tick == Tick.none ? 0 : TickIcon.width + 3);
    painter.dispose();

    // Bounded so a pathological locale cannot grow it without limit.
    if (_cache.length > 256) _cache.clear();
    _cache[key] = w;
    return w;
  }
}
