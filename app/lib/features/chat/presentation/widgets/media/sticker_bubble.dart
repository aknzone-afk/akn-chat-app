import 'package:cached_network_image/cached_network_image.dart';
import '../../../../../core/media/app_image_cache.dart';
import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';
import '../../../domain/message.dart';
import 'media_status_overlay.dart';

/// A sticker.
///
/// Not an [ImageBubble] with a smaller box, for one reason worth stating:
/// stickers are transparent WebP, so `BoxFit.cover` inside a coloured tile
/// would put a grey rectangle behind a shape that is meant to float. This
/// paints it at `BoxFit.contain` with nothing behind it, and there is no
/// full-screen viewer — nobody pinch-zooms a sticker.
///
/// Animated WebP is rendered as a still first frame: `cached_network_image`
/// hands the bytes to Flutter's own codec, which decodes animated WebP fine on
/// Android but not reliably on iOS. A still sticker reads correctly; a broken
/// one does not.
class StickerBubble extends StatelessWidget {
  const StickerBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final side = (MediaQuery.sizeOf(context).width * 0.34).clamp(96.0, 150.0);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final url = message.mediaUrl;

    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url != null && url.isNotEmpty)
            CachedNetworkImage(
              cacheManager: appImageCache,
              imageUrl: url,
              // The STORAGE PATH, never the URL — download URLs carry a
              // rotatable token and a URL-keyed cache re-fetches on every
              // rotation.
              cacheKey: message.mediaPath,
              fit: BoxFit.contain,
              memCacheWidth: (side * dpr).round(),
              fadeInDuration: const Duration(milliseconds: 120),
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => _fallbackGlyph(context),
            )
          else
            _fallbackGlyph(context),
          MediaStatusOverlay(message: message),
        ],
      ),
    );
  }

  Widget _fallbackGlyph(BuildContext context) => Center(
    child: Icon(
      Icons.emoji_emotions_outlined,
      size: 44,
      color: metaTextStyle(Theme.of(context).brightness).color,
    ),
  );
}
