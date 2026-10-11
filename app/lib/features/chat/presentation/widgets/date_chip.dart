import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/format/formatters.dart';

/// "Aaj" / "Kal" / a weekday / a date. Used inline above the first message of
/// each day, and again as the floating sticky chip while scrolling.
class DateChip extends StatelessWidget {
  const DateChip({super.key, required this.date, this.elevated = false});

  final DateTime date;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1D2B33) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(8),
        boxShadow: elevated
            ? const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x12000000),
                  blurRadius: 1,
                  offset: Offset(0, 1),
                ),
              ],
      ),
      child: Text(
        dateChipLabel(date),
        style: TextStyle(
          fontSize: 11.8,
          fontWeight: FontWeight.w500,
          color: isDark ? const Color(0xFFA9BBC5) : const Color(0xFF54656F),
        ),
      ),
    );
  }
}

/// The chip that floats over the list while the user scrolls.
///
/// It lives OUTSIDE the list subtree, fed by a `ValueNotifier` written from the
/// scroll listener, so it can never rebuild a single bubble. A
/// `SliverPersistentHeader` is the wrong tool here: in a reversed list a pinned
/// header sticks to the leading edge, which is the *bottom*.
class StickyDateChip extends StatelessWidget {
  const StickyDateChip({
    super.key,
    required this.date,
    required this.visible,
  });

  final ValueListenable<DateTime?> date;
  final ValueListenable<bool> visible;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: visible,
    builder: (context, show, _) => AnimatedOpacity(
      opacity: show ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        child: ValueListenableBuilder<DateTime?>(
          valueListenable: date,
          builder: (context, value, _) => value == null
              ? const SizedBox.shrink()
              : Center(child: DateChip(date: value, elevated: true)),
        ),
      ),
    ),
  );
}
