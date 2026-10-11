import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/theme.dart';
import '../../../../../core/media/app_image_cache.dart';
import '../../../../../core/media/media_cache.dart';
import '../../../domain/message.dart';
import '../../../providers/chat_providers.dart';
import '../../media/media_viewer_screen.dart';
import 'media_status_overlay.dart';

/// A photo or sticker in the conversation.
///
/// Four rules here are not negotiable, and each one is a bug that has bitten a
/// Flutter chat app before:
///
///  1. **`cacheKey: mediaPath`, never the URL.** Firebase download URLs carry a
///     rotatable `token` query parameter; a URL-keyed cache re-downloads the
///     whole object every time that token changes.
///  2. **`memCacheWidth` always.** Without it a 4000px JPEG decodes to ~64 MB
///     of RGBA *per visible bubble*. This is the single biggest memory win in
///     the whole list.
///  3. **Never call `getDownloadURL()` in `build()` or a `FutureBuilder`.** It
///     is a network round trip per item, and it defeats Hero, which needs a
///     synchronous `ImageProvider`. The URL is already on the document.
///  4. **The local→remote handover must not flash.** `media_uploader.dart`
///     seeds the disk cache under the same key this widget will later read, so
///     when `mediaUrl` lands the bytes are already there.
class ImageBubble extends ConsumerWidget {
  const ImageBubble({
    super.key,
    required this.waId,
    required this.message,
    required this.hasCaption,
  });

  final String waId;
  final Message message;

  /// When there is a caption the meta row goes under the text instead of
  /// floating on the image.
  final bool hasCaption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The bubble's own padding is 9 either side; subtract it so the image sits
    // flush inside the rounded corner rather than overflowing it.
    final maxW = MediaQuery.sizeOf(context).width * Bubbles.maxWidthFactor - 18;
    final w = message.type == MsgType.sticker ? maxW * 0.45 : maxW;
    // Clamp panoramas and skyscrapers so one photo cannot own the whole screen.
    final h = (w / message.mediaAspect).clamp(w * 0.55, w * 1.45);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final radius = BorderRadius.circular(6);

    return GestureDetector(
      onTap: () => _open(context, ref),
      child: Padding(
        padding: EdgeInsets.only(bottom: hasCaption ? 4 : 0),
        child: ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  // Namespaced by MESSAGE id. The same photo can legitimately
                  // appear twice on screen, and duplicate tags throw.
                  tag: 'media_${message.id}',
                  child: _source(context, w, h, dpr),
                ),
                MediaStatusOverlay(
                  message: message,
                  progress: message.uploadProgress,
                ),
                if (!hasCaption)
                  const Positioned(bottom: 0, left: 0, right: 0, child: _Scrim()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Exactly one source, chosen in this order.
  Widget _source(BuildContext context, double w, double h, double dpr) {
    final local = message.localPath;
    // Ours, still uploading (or just uploaded and waiting for the URL). Paint
    // from this phone's own disk — instant, and correct even with no network.
    if (local != null && local.isNotEmpty) {
      return Image.file(
        File(local),
        fit: BoxFit.cover,
        cacheWidth: (w * dpr).round(),
        errorBuilder: (_, _, _) => const _Tint(),
      );
    }

    // WhatsApp-style (4/5-Oct-2026): the server's tiny blurred copy paints at
    // once, then the ~720 px preview fades in on top. The full original is only
    // fetched by the full-screen viewer.
    final thumb = message.thumbUrl;
    final mediaPath = message.mediaPath;
    if (thumb != null && thumb.isNotEmpty && mediaPath != null && mediaPath.isNotEmpty) {
      final blur = _blurBytes(message.thumbB64);
      final placeholder = blur != null
          ? Image.memory(blur, fit: BoxFit.cover, gaplessPlayback: true)
          : const _Tint();
      return CachedNetworkImage(
        imageUrl: thumb,
        cacheKey: thumbKey(mediaPath),
        cacheManager: appImageCache,
        fit: BoxFit.cover,
        memCacheWidth: (w * dpr).round(),
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }

    final url = message.mediaUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        cacheKey: message.mediaPath,
        cacheManager: appImageCache,
        fit: BoxFit.cover,
        memCacheWidth: (w * dpr).round(),
        maxWidthDiskCache: 1600,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => const _Tint(),
        errorWidget: (_, _, _) => const _Tint(
          child: Icon(Icons.broken_image_outlined, color: Colors.white70),
        ),
      );
    }

    // No URL, but the bytes ARE in our bucket. This is the rescue path for a
    // download URL that could not be minted (it is a metadata write against
    // GCS, so it fails transiently) — without it that photo was an unviewable
    // grey box on every phone, permanently, with nothing in the system able to
    // repair it. Reading by path is slower than the CDN and correct.
    final path = message.mediaPath;
    if (path != null && path.isNotEmpty) {
      return _StorageImage(
        storagePath: path,
        width: w,
        height: h,
        dpr: dpr,
      );
    }

    return const _Tint();
  }

  /// Decoded blur bytes, memoised per message so scrolling does not re-decode.
  static final Map<String, Uint8List> _blurCache = <String, Uint8List>{};

  static Uint8List? _blurBytes(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    final hit = _blurCache[b64];
    if (hit != null) return hit;
    try {
      final bytes = base64Decode(b64);
      if (_blurCache.length > 400) _blurCache.clear();
      return _blurCache[b64] = bytes;
    } catch (_) {
      return null;
    }
  }

  void _open(BuildContext context, WidgetRef ref) {
    if (mediaPhaseOf(message) != MediaPhase.ready) return;
    final items = ref.read(chatMediaProvider(waId));
    final index = items.indexWhere((i) => i.messageId == message.id);
    if (index < 0) return;
    openMediaViewer(context, ref, waId: waId, items: items, initialIndex: index);
  }
}

/// The last resort: fetch the object out of Firebase Storage by PATH.
///
/// Deliberately not the normal route — `CachedNetworkImage` on `mediaUrl` is
/// faster, CDN-backed and has its own decode-at-display-size LRU. This exists
/// only for a row whose `mediaUrl` could not be minted, which used to be an
/// unrecoverable grey box. `MediaCache.file` de-duplicates concurrent callers
/// and downloads once, ever, so a chat full of these costs one fetch each.
class _StorageImage extends StatefulWidget {
  const _StorageImage({
    required this.storagePath,
    required this.width,
    required this.height,
    required this.dpr,
  });

  final String storagePath;
  final double width;
  final double height;
  final double dpr;

  @override
  State<_StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<_StorageImage> {
  late Future<File> _future = MediaCache.file(widget.storagePath);

  @override
  void didUpdateWidget(covariant _StorageImage old) {
    super.didUpdateWidget(old);
    if (old.storagePath != widget.storagePath) {
      _future = MediaCache.file(widget.storagePath);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: _future,
    builder: (context, snap) {
      final file = snap.data;
      if (file == null) return const _Tint();
      return Image.file(
        file,
        fit: BoxFit.cover,
        // Same rule as everywhere else: without this a 4000px JPEG decodes to
        // ~64 MB of RGBA per visible bubble.
        cacheWidth: (widget.width * widget.dpr).round(),
        errorBuilder: (_, _, _) => const _Tint(),
      );
    },
  );
}

class _Tint extends StatelessWidget {
  const _Tint({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: isDark ? const Color(0xFF16232B) : const Color(0xFFE3DDD6),
      child: Center(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// A soft dark gradient behind the floating time + ticks, so they stay readable
/// over a pale saree photograph.
class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0x66000000), Color(0x00000000)],
      ),
    ),
  );
}
