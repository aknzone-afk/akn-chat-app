import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/media/media_limits.dart';
import '../../domain/media_attachment.dart';
import 'attach_sheet.dart';

/// Preview what is about to be sent, type a caption per item, and send.
///
/// Compression starts the instant an item is picked (in [showAttachSheet]),
/// not when send is tapped — so by the time a caption has been typed the bytes
/// are almost always ready and the send is instantaneous. The send button waits
/// only for the stragglers.
///
/// Returns the (possibly edited, possibly shortened) list to send, or null if
/// the staff member backed out.
Future<List<MediaAttachment>?> showCaptionScreen(
  BuildContext context, {
  required List<MediaAttachment> items,
  required String contactName,
}) => Navigator.of(context).push<List<MediaAttachment>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => CaptionScreen(items: items, contactName: contactName),
  ),
);

class CaptionScreen extends StatefulWidget {
  const CaptionScreen({
    super.key,
    required this.items,
    required this.contactName,
  });

  final List<MediaAttachment> items;
  final String contactName;

  @override
  State<CaptionScreen> createState() => _CaptionScreenState();
}

class _CaptionScreenState extends State<CaptionScreen> {
  late final List<MediaAttachment> _items = [...widget.items];
  late final PageController _pages = PageController();
  final TextEditingController _caption = TextEditingController();
  final FocusNode _focus = FocusNode();

  int _index = 0;

  @override
  void initState() {
    super.initState();
    _caption.text = _items.isEmpty ? '' : _items.first.caption;
    unawaited(_prepareAll());
  }

  /// ONE AT A TIME, and that is not a style preference.
  ///
  /// `prepareAttachment` → `toChatJpeg` decodes the full bitmap NATIVELY, and
  /// pass 1 deliberately does not resize. Ten 12 MP photos started together is
  /// ten ~50 MB native bitmaps plus ten full-resolution q100 buffers on the Dart
  /// heap at the same moment — around half a gigabyte, on 4 GB warehouse
  /// handsets, at the exact moment the staff member is looking at the screen.
  /// That is dropped frames at best and an OOM kill (losing all ten photos) at
  /// worst. Sequential costs the same total time, and each item still flips its
  /// own spinner off as it lands.
  Future<void> _prepareAll() async {
    // A snapshot, because `_remove` mutates `_items` and this loop awaits
    // between iterations — walking the live list would throw
    // ConcurrentModificationError the moment somebody taps an × while a photo
    // is still compressing. Preparing an item that has since been removed is
    // harmless; it is just discarded.
    for (final item in [..._items]) {
      await prepareAttachment(item);
      if (!mounted) return;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _caption.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The caption belongs to whichever item the PageView is on, WhatsApp-style.
  /// Switching items commits whatever is in the field.
  void _commitCaption() {
    if (_index >= 0 && _index < _items.length) {
      _items[_index].caption = _caption.text;
    }
  }

  void _onPageChanged(int next) {
    _commitCaption();
    setState(() {
      _index = next;
      _caption.text = _items[next].caption;
      _caption.selection = TextSelection.collapsed(
        offset: _caption.text.length,
      );
    });
  }

  void _remove(int at) {
    _commitCaption();
    setState(() {
      _items.removeAt(at);
      if (_items.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      _index = _index.clamp(0, _items.length - 1);
      _caption.text = _items[_index].caption;
      if (_pages.hasClients) _pages.jumpToPage(_index);
    });
  }

  void _send() {
    _commitCaption();
    final sendable = _items.where((i) => !i.failed).toList();
    if (sendable.isEmpty) return;
    Navigator.of(context).pop(sendable);
  }

  bool get _canSend =>
      _items.isNotEmpty &&
      _items.every((i) => i.ready) &&
      _items.any((i) => !i.failed);

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          _items.length == 1 ? widget.contactName : '${_items.length} items',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: _items.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (_, i) => _Preview(item: _items[i]),
            ),
          ),
          if (_items.length > 1)
            _Filmstrip(
              items: _items,
              selected: _index,
              onSelect: (i) => _pages.jumpToPage(i),
              onRemove: _remove,
            ),
          SafeArea(top: false, child: _bottomBar(context)),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    // Image, video AND document all take a caption on the WhatsApp Cloud API
    // (only audio and sticker do not, and neither is sendable here), so the
    // field is always live.
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(22),
              ),
              child: TextField(
                controller: _caption,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                // Mirrors Meta's own 1024-character cap and firestore.rules.
                // Enforcing it in the field means the rule can never reject a
                // send for length, which would look like a message that simply
                // refuses to go.
                maxLength: MetaLimits.caption,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                buildCounter:
                    (
                      context, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => currentLength > 950
                    ? Text(
                        '${MetaLimits.caption - currentLength}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      )
                    : null,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Caption likhein (optional)',
                  hintStyle: TextStyle(color: Colors.white54),
                  contentPadding: EdgeInsets.fromLTRB(16, 12, 12, 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendFab(enabled: _canSend, onTap: _send),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.item});

  final MediaAttachment item;

  @override
  Widget build(BuildContext context) {
    if (item.failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.white70,
                size: 44,
              ),
              const SizedBox(height: 12),
              Text(
                item.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (item.type == 'document') {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.description_rounded,
              size: 82,
              color: Colors.white70,
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                item.fileName ?? 'Document',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _bytes(item.sourceBytes),
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
          ],
        ),
      );
    }

    if (item.type == 'video') {
      return Stack(
        alignment: Alignment.center,
        children: [
          const ColoredBox(color: Colors.black, child: SizedBox.expand()),
          const Icon(
            Icons.play_circle_fill_rounded,
            size: 74,
            color: Colors.white70,
          ),
          Positioned(
            bottom: 24,
            child: Text(
              '🎥 ${_bytes(item.sourceBytes)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
        ],
      );
    }

    // Before compression finishes, `previewPath` IS the picker's output — full
    // sensor resolution, because image_picker only downscales when maxWidth /
    // maxHeight are given and neither is. A 4032×3024 capture decodes to 48.7 MB
    // of RGBA, which on its own evicts Flutter's entire 100 MB image cache and
    // uploads a 48 MB texture. Decode at screen width instead.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (MediaQuery.sizeOf(context).width * dpr).round();

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(item.previewPath),
          fit: BoxFit.contain,
          cacheWidth: decodeWidth,
          // `previewPath` swaps from the source file to the compressed one the
          // moment compression lands; without this the preview blinks white.
          gaplessPlayback: true,
        ),
        if (!item.ready)
          const Center(
            child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            ),
          ),
      ],
    );
  }

  static String _bytes(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
  }
}

class _Filmstrip extends StatelessWidget {
  const _Filmstrip({
    required this.items,
    required this.selected,
    required this.onSelect,
    required this.onRemove,
  });

  final List<MediaAttachment> items;
  final int selected;
  final void Function(int) onSelect;
  final void Function(int) onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 68,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final item = items[i];
        return GestureDetector(
          onTap: () => onSelect(i),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: i == selected ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                  color: Colors.white12,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: item.type == 'image'
                      ? Image.file(
                          File(item.previewPath),
                          fit: BoxFit.cover,
                          cacheWidth: 160,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.image, color: Colors.white38),
                        )
                      : Icon(
                          item.type == 'video'
                              ? Icons.videocam_rounded
                              : Icons.description_rounded,
                          color: Colors.white70,
                        ),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: GestureDetector(
                  onTap: () => onRemove(i),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _SendFab extends StatelessWidget {
  const _SendFab({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: enabled ? const Color(0xFF1B7F5A) : Colors.white24,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 50,
        height: 50,
        child: Icon(
          Icons.send_rounded,
          size: 21,
          color: enabled ? Colors.white : Colors.white38,
        ),
      ),
    ),
  );
}
