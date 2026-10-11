import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../../app/theme.dart';
import '../../../../../core/media/media_cache.dart';
import '../../../../../core/media/media_limits.dart';
import '../../../../../core/widgets/states.dart';
import '../../../domain/message.dart';
import '../../media/document_viewer_screen.dart';
import 'media_status_overlay.dart';

/// A PDF, spreadsheet or Word file. Tap opens it in whatever app the phone has;
/// long-press shares it.
class DocumentTile extends StatefulWidget {
  const DocumentTile({super.key, required this.message});

  final Message message;

  @override
  State<DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends State<DocumentTile> {
  bool _busy = false;

  Message get _m => widget.message;

  String get _extension {
    final name = _m.fileName ?? '';
    final dot = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      return name.substring(dot + 1).toUpperCase();
    }
    return extForMime(_m.mediaMime ?? '').toUpperCase();
  }

  ({IconData icon, Color colour}) get _glyph => switch (_extension) {
    'PDF' => (icon: Icons.picture_as_pdf_rounded, colour: const Color(0xFFD64541)),
    'XLS' || 'XLSX' || 'CSV' => (
      icon: Icons.table_chart_rounded,
      colour: const Color(0xFF2E7D4F),
    ),
    'DOC' || 'DOCX' => (
      icon: Icons.article_rounded,
      colour: const Color(0xFF2B579A),
    ),
    'PPT' || 'PPTX' => (
      icon: Icons.slideshow_rounded,
      colour: const Color(0xFFD24726),
    ),
    'TXT' => (icon: Icons.notes_rounded, colour: const Color(0xFF6B7A82)),
    _ => (icon: Icons.insert_drive_file_rounded, colour: const Color(0xFF6B7A82)),
  };

  /// The local file, downloading it once if we do not already have it.
  /// 11-Oct-2026: one quiet retry — a dropped mobile connection must not show
  /// the owner an error for a file that is safely in our bucket.
  Future<File?> _resolve() async {
    final local = _m.localPath;
    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      return File(local);
    }
    final path = _m.mediaPath;
    if (path == null) return null;
    try {
      return await MediaCache.file(path, url: _m.mediaUrl);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return MediaCache.file(path, url: _m.mediaUrl);
    }
  }

  bool get _isPdf =>
      _extension == 'PDF' || baseMime(_m.mediaMime) == 'application/pdf';

  Future<void> _open() async {
    if (_busy || mediaPhaseOf(_m) != MediaPhase.ready) return;
    setState(() => _busy = true);
    try {
      File? file;
      try {
        file = await _resolve();
      } catch (e) {
        // The short reason in brackets lets us see WHY from a screenshot.
        final why = e.toString().replaceAll(RegExp(r'\s+'), ' ');
        if (mounted) {
          showAknSnack(context,
              '${MediaMessages.downloadFailed} [${why.length > 80 ? why.substring(0, 80) : why}]',
              isError: true);
        }
        return;
      }
      if (file == null) {
        if (mounted) showAknSnack(context, MediaMessages.fileNotFound, isError: true);
        return;
      }
      if (!mounted) return;
      // 11-Oct-2026: PDFs open in our own viewer — never "File khul nahi paayi".
      if (_isPdf) {
        await DocumentViewerScreen.open(
          context,
          file: file,
          title: _m.fileName ?? 'Document.pdf',
          mimeType: 'application/pdf',
        );
        return;
      }
      OpenResult? result;
      try {
        result = await OpenFilex.open(
          file.path,
          // Android: skip the plugin's own extension sniffing — our object names
          // are derived from the MIME, not from the customer's file name.
          // iOS: `type` is an Apple UTI ("com.adobe.pdf"), NOT a MIME.
          type: Platform.isIOS ? null : baseMime(_m.mediaMime),
        );
      } catch (_) {
        result = null;
      }
      if (!mounted) return;
      // Anything the phone could not open itself goes to the share sheet
      // ("Open in…", Save to Files, Quick Look) instead of an error.
      if (result == null || result.type != ResultType.done) await _share();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (mediaPhaseOf(_m) != MediaPhase.ready) return;
    // Captured BEFORE the await: the widget may be gone by the time the
    // download finishes, and `context.findRenderObject()` on a dead element
    // throws.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      final file = await _resolve();
      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: baseMime(_m.mediaMime))],
          // Passed UNCONDITIONALLY: omitting it crashes the share sheet on
          // iPad, and the null case is handled by share_plus itself.
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      if (mounted) showAknSnack(context, MediaMessages.openFailed, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final metaColour = metaTextStyle(brightness).color;
    final glyph = _glyph;
    final phase = mediaPhaseOf(_m);
    final status = mediaStatusLabel(_m);

    final size = formatBytes(_m.fileSize);
    final subtitle = status ?? [if (size.isNotEmpty) size, _extension].join(' · ');

    return GestureDetector(
      onTap: _open,
      onLongPress: _share,
      child: Container(
        constraints: const BoxConstraints(minWidth: 210),
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
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: glyph.colour.withValues(alpha: isDark ? 0.22 : 0.13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(glyph.icon, size: 21, color: glyph.colour),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _m.fileName ?? 'Document',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: bubbleTextStyle(brightness).copyWith(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: metaColour),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 24,
              height: 24,
              child: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      switch (phase) {
                        MediaPhase.ready => Icons.download_rounded,
                        MediaPhase.working => Icons.hourglass_empty_rounded,
                        MediaPhase.stalled => Icons.hourglass_bottom_rounded,
                        MediaPhase.dead => Icons.error_outline_rounded,
                      },
                      size: 20,
                      color: metaColour,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
