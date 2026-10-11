import 'dart:io';
import '../../../../core/media/app_image_cache.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/format/formatters.dart';
import '../../../../core/media/media_cache.dart';
import '../../../../core/widgets/states.dart';
import '../../domain/media_item.dart';
import '../../providers/chat_providers.dart';

/// Open the gallery.
///
/// Deliberately an imperative push and NOT a `go_router` route: the item list
/// is derived from whatever the chat has currently loaded and is not
/// serialisable into a path, and `opaque: false` is what makes the Hero fly
/// over the conversation instead of landing on a white slab.
void openMediaViewer(
  BuildContext context,
  WidgetRef ref, {
  required String waId,
  required List<MediaItem> items,
  required int initialIndex,
}) {
  if (items.isEmpty) return;
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => MediaViewerScreen(
        waId: waId,
        items: items,
        initialIndex: initialIndex.clamp(0, items.length - 1),
      ),
    ),
  );
}

class MediaViewerScreen extends ConsumerStatefulWidget {
  const MediaViewerScreen({
    super.key,
    required this.waId,
    required this.items,
    required this.initialIndex,
  });

  final String waId;
  final List<MediaItem> items;
  final int initialIndex;

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );

  /// Reset zoom on page change, or a page you zoomed into stays zoomed when you
  /// swipe back to it.
  final PhotoViewScaleStateController _scale = PhotoViewScaleStateController();

  /// Seeded from the push, then kept in step with the chat.
  ///
  /// Held in State rather than watched straight into `build()` because
  /// `loadOlder()` PREPENDS: every existing index shifts underneath the
  /// PageController, so the list and the current page have to move together.
  ///
  /// Without this the viewer rendered `widget.items` — the snapshot taken when
  /// the route was pushed — for ever. `loadOlder()` fired at index 0 and updated
  /// `chatMediaProvider` where nothing could reach it, so a customer's 60 photos
  /// stopped dead at "1 / 30" and staff had to close the viewer, scroll the
  /// conversation and reopen.
  late List<MediaItem> _items = widget.items;

  late int _current = widget.initialIndex;
  bool _chromeVisible = true;

  /// Where a pointer went down, for the raw tap detection below.
  Offset? _tapOrigin;

  @override
  void dispose() {
    _pages.dispose();
    _scale.dispose();
    super.dispose();
  }

  MediaItem get _item => _items[_current];

  void _onPageChanged(int index) {
    _scale.reset();
    setState(() => _current = index);

    // Reaching the oldest loaded item nudges history, so swiping back through a
    // long day of photos keeps working instead of stopping at an arbitrary
    // wall. Index 0 is the OLDEST — chatMediaProvider is oldest-first.
    if (index == 0) {
      ref.read(messageHistoryProvider(widget.waId).notifier).loadOlder();
    }
  }

  /// Absorb a longer list without moving what is on screen.
  void _onItemsChanged(List<MediaItem> next) {
    if (next.length <= _items.length || _current >= _items.length) return;
    // Re-anchor on the message being LOOKED AT. New items can land at either
    // end — an inbound photo arrives at the newest end while history loads at
    // the oldest — so a length delta is not a safe shift.
    final id = _items[_current].messageId;
    final at = next.indexWhere((i) => i.messageId == id);
    if (at < 0) return;
    setState(() {
      _items = next;
      _current = at;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The content at the new index is byte-identical, so this is invisible.
      if (!mounted) return;
      if (_pages.hasClients && _pages.page?.round() != at) {
        _pages.jumpToPage(at);
      }
    });
  }

  Future<void> _share() async {
    final item = _item;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      final local = item.localPath;
      final file = local != null && local.isNotEmpty && File(local).existsSync()
          ? File(local)
          : await MediaCache.file(item.cacheKey);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], sharePositionOrigin: origin),
      );
    } catch (_) {
      if (mounted) {
        showAknSnack(context, 'Share nahi ho paaya.', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<MediaItem>>(
      chatMediaProvider(widget.waId),
      (_, next) => _onItemsChanged(next),
    );

    final item = _item;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _chromeVisible
          ? AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.35),
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              iconTheme: const IconThemeData(color: Colors.white),
              title: Text(
                '${_current + 1} / ${_items.length}',
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              actions: [
                IconButton(
                  tooltip: 'Share karein',
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share_rounded),
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          // A raw Listener, NOT a GestureDetector. photo_view installs a
          // DoubleTapGestureRecognizer on every page unconditionally, and on the
          // first tap-up that recognizer calls gestureArena.hold() and waits out
          // kDoubleTapTimeout — 300 ms — before releasing. An outer onTap is
          // last into the arena and cannot win by sweep until that hold expires,
          // so tapping the photo to get the app bar out of the way lagged by a
          // third of a second, every tap, both directions. A pointer that never
          // moved is unambiguously a tap and cannot conflict with pan, pinch or
          // paging.
          Listener(
            onPointerDown: (e) => _tapOrigin = e.position,
            onPointerUp: (e) {
              final origin = _tapOrigin;
              _tapOrigin = null;
              if (origin == null) return;
              if ((e.position - origin).distance > kTouchSlop) return;
              setState(() => _chromeVisible = !_chromeVisible);
            },
            onPointerCancel: (_) => _tapOrigin = null,
            child: PhotoViewGallery.builder(
              itemCount: _items.length,
              pageController: _pages,
              onPageChanged: _onPageChanged,
              scrollPhysics: const BouncingScrollPhysics(),
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              builder: (context, index) => _page(_items[index], index),
            ),
          ),
          if (_chromeVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _CaptionStrip(item: item),
            ),
        ],
      ),
    );
  }

  PhotoViewGalleryPageOptions _page(MediaItem item, int index) {
    if (item.isVideo) {
      return PhotoViewGalleryPageOptions.customChild(
        // photo_view's gesture arena fights Chewie's controls: a drag meant for
        // the scrub bar gets eaten as a pan. The video page does its own
        // zooming (it does not need any) so hand the gestures over entirely.
        disableGestures: true,
        heroAttributes: PhotoViewHeroAttributes(tag: item.heroTag),
        child: _VideoPage(item: item),
      );
    }

    final local = item.localPath;
    // The provider MUST be constructed synchronously — a Hero has nothing to
    // fly to if the provider is awaited inside a FutureBuilder. This is exactly
    // why the download URL is already on the document.
    final ImageProvider provider =
        local != null && local.isNotEmpty && File(local).existsSync()
        ? FileImage(File(local))
        : CachedNetworkImageProvider(
            item.url ?? '',
            cacheKey: item.cacheKey,
            cacheManager: appImageCache,
          );

    return PhotoViewGalleryPageOptions(
      imageProvider: provider,
      heroAttributes: PhotoViewHeroAttributes(tag: item.heroTag),
      initialScale: PhotoViewComputedScale.contained,
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4.0,
      filterQuality: FilterQuality.medium,
      scaleStateController: index == _current ? _scale : null,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 54),
      ),
    );
  }
}

/// One video page. The controller is created on mount and disposed on unmount,
/// so at most a couple ever exist — `PhotoViewGallery` only mounts the visible
/// page and its immediate neighbours.
class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.item});

  final MediaItem item;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final local = widget.item.localPath;
      final controller =
          local != null && local.isNotEmpty && File(local).existsSync()
          ? VideoPlayerController.file(File(local))
          : VideoPlayerController.networkUrl(Uri.parse(widget.item.url ?? ''));

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _video = controller;
        _chewie = ChewieController(
          videoPlayerController: controller,
          aspectRatio: controller.value.aspectRatio,
          autoPlay: true,
          looping: false,
          allowFullScreen: false, // we ARE full screen
          allowPlaybackSpeedChanging: true,
          showControlsOnInitialize: true,
          materialProgressColors: ChewieProgressColors(
            playedColor: const Color(0xFF25D366),
          ),
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Ye video chal nahi paayi.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    final chewie = _chewie;
    if (chewie == null) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(Colors.white),
        ),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: _video!.value.aspectRatio,
        child: Chewie(controller: chewie),
      ),
    );
  }
}

class _CaptionStrip extends StatelessWidget {
  const _CaptionStrip({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final caption = item.caption?.trim();
    final who = item.isOutgoing ? 'Aapne bheja' : 'Customer';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$who · ${bubbleTime(item.timestamp)}',
            style: const TextStyle(fontSize: 11.5, color: Colors.white70),
          ),
          if (caption != null && caption.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              caption,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14.5,
                height: 1.3,
                color: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
