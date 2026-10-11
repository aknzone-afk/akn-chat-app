import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

/// 11-Oct-2026: PDFs open INSIDE the app, WhatsApp-style. Handing the file to
/// iOS (open_filex) kept failing with "File khul nahi paayi" on the owner's
/// iPhone; our own viewer needs no other app and no file-type guessing.
/// The share button in the top bar still offers Save / Print / Open in.
class DocumentViewerScreen extends StatelessWidget {
  const DocumentViewerScreen({
    super.key,
    required this.file,
    required this.title,
    this.mimeType,
  });

  final File file;
  final String title;
  final String? mimeType;

  static Future<void> open(
    BuildContext context, {
    required File file,
    required String title,
    String? mimeType,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DocumentViewerScreen(file: file, title: title, mimeType: mimeType),
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType, name: title)],
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3A3A3A),
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16)),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Share / Save',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => _share(ctx),
            ),
          ),
        ],
      ),
      body: PdfViewer.file(
        file.path,
        params: PdfViewerParams(
          backgroundColor: const Color(0xFF3A3A3A),
          maxScale: 8,
          errorBannerBuilder: (context, error, stackTrace, documentRef) =>
              _Unreadable(onShare: () => _share(context)),
        ),
      ),
    );
  }
}

class _Unreadable extends StatelessWidget {
  const _Unreadable({required this.onShare});
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.picture_as_pdf_rounded, size: 56, color: Colors.white70),
          const SizedBox(height: 12),
          const Text('Ye PDF yahan nahi dikh rahi — doosre app me kholiye.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onShare,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open in…'),
          ),
        ]),
      ),
    );
  }
}
