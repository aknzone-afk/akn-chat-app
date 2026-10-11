import 'package:flutter/material.dart';

import '../../../../core/widgets/shimmer.dart';

/// The conversation while the very first snapshot loads.
///
/// Built with the SAME `reverse: true` list as the real thing, so the geometry,
/// padding and bottom anchor match exactly and the swap is a cross-fade rather
/// than a visible jump. The rest of the screen — the header with the contact's
/// name, the composer, the wallpaper — is already real and already interactive,
/// which a full-screen spinner would have blocked.
class ChatSkeleton extends StatelessWidget {
  const ChatSkeleton({super.key});

  // Deterministic. A `Random()` inside `itemBuilder` reshuffles on every
  // shimmer frame and looks like static.
  static const _widths = [0.62, 0.34, 0.75, 0.46, 0.55, 0.28, 0.70, 0.40];
  static const _mine = [false, true, false, false, true, true, false, true];
  static const _tall = [true, false, true, false, false, false, true, false];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    return RepaintBoundary(
      child: Shimmer(
        child: ListView.builder(
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          itemCount: 12,
          itemBuilder: (context, i) {
            final mine = _mine[i % _mine.length];
            return Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Bone(
                  width: width * _widths[i % _widths.length],
                  height: _tall[i % _tall.length] ? 58 : 34,
                  radius: 9,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
