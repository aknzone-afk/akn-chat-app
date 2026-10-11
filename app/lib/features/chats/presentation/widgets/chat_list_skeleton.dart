import 'package:flutter/material.dart';

import '../../../../core/widgets/shimmer.dart';

/// The home screen while the first snapshot is on its way.
///
/// It occupies the final geometry, so swapping in the real list is a cross-fade
/// rather than a full-viewport relayout — which is most of what "feels like
/// WhatsApp" actually means. A centred spinner would be replaced by a list and
/// everything would jump.
class ChatListSkeleton extends StatelessWidget {
  const ChatListSkeleton({super.key, this.rows = 9});

  final int rows;

  /// Deterministic, NOT `Random()`. A fresh random width inside `itemBuilder`
  /// reshuffles on every shimmer frame — 60 times a second — and reads as
  /// static rather than as loading.
  static const _nameWidths = [0.42, 0.30, 0.52, 0.36, 0.46, 0.26, 0.50];
  static const _previewWidths = [0.68, 0.55, 0.78, 0.48, 0.72, 0.60, 0.64];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    return RepaintBoundary(
      child: Shimmer(
        child: ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: rows,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
            child: Row(
              children: [
                const Bone(width: 50, height: 50, radius: 25),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Bone(
                        width: width * _nameWidths[i % _nameWidths.length],
                        height: 14,
                      ),
                      const SizedBox(height: 9),
                      Bone(
                        width: width * _previewWidths[i % _previewWidths.length],
                        height: 11,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const Bone(width: 30, height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
