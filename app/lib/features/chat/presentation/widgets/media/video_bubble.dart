import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/theme.dart';
import '../../../domain/message.dart';
import '../../../providers/chat_providers.dart';
import '../../media/media_viewer_screen.dart';
import 'media_status_overlay.dart';

/// A video in the conversation: a dark tile, a play glyph, the duration and the
/// size. Tap opens the full-screen player.
///
/// NO POSTER FRAME, and that is deliberate rather than unfinished. Generating
/// one means downloading the video (wrong in a list — a 14 MB fetch per bubble
/// as you scroll), or an ffmpeg pass on the client (`ffmpeg_kit_flutter` is
/// retired and its binaries are gone), or a second heavyweight Cloud Function.
/// Adding posters later is one `mediaThumbPath` field and one more rules key.
///
/// ⚠️ NEVER initialise a `VideoPlayerController` here. Each one holds a
/// platform decoder, and Android throws MediaCodec exhaustion at roughly 6–10
/// concurrent instances — which a chat list will reach within one flick of the
/// thumb. The controller is created inside the viewer, one at a time.
class VideoBubble extends ConsumerWidget {
  const VideoBubble({
    super.key,
    required this.waId,
    required this.message,
    required this.hasCaption,
  });

  final String waId;
  final Message message;
  final bool hasCaption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxW = MediaQuery.sizeOf(context).width * Bubbles.maxWidthFactor - 18;
    final h = (maxW / message.mediaAspect).clamp(maxW * 0.55, maxW * 1.0);

    return GestureDetector(
      onTap: () => _open(context, ref),
      child: Padding(
        padding: EdgeInsets.only(bottom: hasCaption ? 4 : 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: maxW,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: 'media_${message.id}',
                  child: const ColoredBox(color: Color(0xFF11181C)),
                ),
                if (mediaPhaseOf(message) == MediaPhase.ready)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      size: 54,
                      color: Colors.white,
                    ),
                  ),
                Positioned(
                  top: 6,
                  left: 8,
                  child: _Chip(
                    label: [
                      '🎥 Video',
                      if (formatBytes(message.fileSize).isNotEmpty)
                        formatBytes(message.fileSize),
                    ].join(' · '),
                  ),
                ),
                MediaStatusOverlay(
                  message: message,
                  progress: message.uploadProgress,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref) {
    if (mediaPhaseOf(message) != MediaPhase.ready) return;
    final items = ref.read(chatMediaProvider(waId));
    final index = items.indexWhere((i) => i.messageId == message.id);
    if (index < 0) return;
    openMediaViewer(context, ref, waId: waId, items: items, initialIndex: index);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 11, color: Colors.white),
    ),
  );
}
