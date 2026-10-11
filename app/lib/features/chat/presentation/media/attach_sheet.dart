import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:uuid/uuid.dart';

import '../../../../app/theme.dart';
import '../../../../core/media/compress.dart';
import '../../../../core/media/media_limits.dart';
import '../../../../core/widgets/states.dart';
import '../../domain/media_attachment.dart';

const _uuid = Uuid();
final ImagePicker _picker = ImagePicker();

/// Call ONCE in `main()`, before any pick.
///
/// On Android 13+ the system Photo Picker is used by default; setting this flag
/// also gives us the picker on 12 and below, and it is what makes `limit:`
/// actually take effect. It matters for policy as well as ergonomics: going
/// through the Photo Picker is what lets us declare ZERO storage permissions,
/// and declaring `READ_MEDIA_IMAGES` for one-off picking is a Play Photo &
/// Video Permissions violation that gets apps rejected.
void enableAndroidPhotoPicker() {
  final platform = ImagePickerPlatform.instance;
  if (platform is ImagePickerAndroid) {
    platform.useAndroidPhotoPicker = true;
  }
}

/// The three-option sheet. THREE, not six: four staff members use this at arm's
/// length in a warehouse, so the targets are large and the choices are few.
Future<List<MediaAttachment>?> showAttachSheet(BuildContext context) async {
  final choice = await showModalBottomSheet<_AttachChoice>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Kya bhejna hai?',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
              ),
            ),
            Row(
              children: [
                _AttachOption(
                  icon: Icons.photo_camera_rounded,
                  label: 'Camera',
                  colour: const Color(0xFFD64541),
                  onTap: () => Navigator.pop(context, _AttachChoice.camera),
                ),
                _AttachOption(
                  icon: Icons.photo_library_rounded,
                  label: 'Gallery',
                  colour: AknColors.maroonLight,
                  onTap: () => Navigator.pop(context, _AttachChoice.gallery),
                ),
                _AttachOption(
                  icon: Icons.description_rounded,
                  label: 'Document',
                  colour: const Color(0xFF2B579A),
                  onTap: () => Navigator.pop(context, _AttachChoice.document),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  if (choice == null || !context.mounted) return null;

  // The picker is a full platform activity, so `context` is always crossing an
  // async gap here. Rejections are collected and reported by the caller once
  // the context is known to be alive again, rather than sprinkling `mounted`
  // checks through the picking code.
  final ({List<MediaAttachment> items, String? problem}) outcome;
  try {
    outcome = switch (choice) {
      _AttachChoice.camera => await _pickCamera(),
      _AttachChoice.gallery => await _pickGallery(),
      _AttachChoice.document => await _pickDocument(),
    };
  } catch (e) {
    debugPrint('attach failed: $e');
    if (context.mounted) {
      // Technical reason appended on purpose — see the note at the compression
      // catch below. Remove once media has been stable for a week.
      showAknSnack(
        context,
        '${MediaMessages.compressionFailed} [$e]',
        isError: true,
      );
    }
    return null;
  }

  if (!context.mounted) return null;
  if (outcome.problem != null) {
    showAknSnack(context, outcome.problem!, isError: true);
  }
  return outcome.items.isEmpty ? null : outcome.items;
}

/// What a pick produced, plus the first reason anything was turned away.
typedef _PickResult = ({List<MediaAttachment> items, String? problem});

const _PickResult _nothing = (items: <MediaAttachment>[], problem: null);

enum _AttachChoice { camera, gallery, document }

// ⚠️ WHY THE PICKER RESIZES, AND WHY THIS CHANGED.
//
// The original code asked the picker for the untouched original, on the theory
// that fewer picker-side re-encodes meant sharper fabric texture. On an
// iPhone 17 Pro that theory broke: the original is a 48-megapixel HEIC, and
// `toChatJpeg` then drew it into a full-size bitmap (~195 MB) at quality 100
// before shrinking it. Photos failed to send at all — the native call returned
// nothing and staff saw "Photo taiyaar nahi ho paayi".
//
// Handing the picker `maxWidth`/`maxHeight` makes iOS/Android do the downscale
// NATIVELY, with proper downsampling, never holding the full bitmap. It also
// converts HEIC → JPEG on the way out, which is the whole reason the expensive
// first pass existed.
//
// Quality actually IMPROVES: this is ONE lossy generation at the target size
// instead of three (original → q100 full-size → q82 resized). `toChatJpeg`
// downstream now sees an already-correct JPEG and passes it through.
//
// A little headroom above the 1600px target so `toChatJpeg` still owns the
// exact final dimensions and nothing is upscaled.
const double _kPickerMaxEdge = 2048;

Future<_PickResult> _pickCamera() async {
  final shot = await _picker.pickImage(
    source: ImageSource.camera,
    preferredCameraDevice: CameraDevice.rear,
    maxWidth: _kPickerMaxEdge,
    maxHeight: _kPickerMaxEdge,
    // EXIF (and with it GPS) is stripped during compression regardless; not
    // requesting it in the first place is one less copy of a customer's
    // location on disk.
    requestFullMetadata: false,
  );
  if (shot == null) return _nothing;
  return _fromPicked([shot]);
}

Future<_PickResult> _pickGallery() async {
  // Images AND videos in one picker, which is what staff expect.
  // `pickMultipleMedia` applies maxWidth/maxHeight to images and leaves videos
  // untouched, which is exactly what we want.
  final picked = await _picker.pickMultipleMedia(
    limit: 10,
    maxWidth: _kPickerMaxEdge,
    maxHeight: _kPickerMaxEdge,
  );
  if (picked.isEmpty) return _nothing;
  return _fromPicked(picked);
}

Future<_PickResult> _pickDocument() async {
  // Static, not `FilePicker.platform.pickFiles` — file_picker 11 made
  // `FilePicker` an `abstract final class` with static methods.
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: MetaLimits.documentExtensions,
    allowMultiple: false,
    // NOT true: `withData: true` loads a 30 MB PDF into the Dart heap for no
    // reason at all. We only want the path.
    withData: false,
  );

  final file = result?.files.firstOrNull;
  final path = file?.path;
  if (file == null || path == null) return _nothing;

  final name = file.name;
  final mime = mimeForExtension(name);
  final size = file.size;

  if (mime == null || !MetaLimits.documentMimes.contains(mime)) {
    return (
      items: const <MediaAttachment>[],
      problem: MediaMessages.unsupportedDocument,
    );
  }
  if (size > MetaLimits.document) {
    return (
      items: const <MediaAttachment>[],
      problem: MediaMessages.documentTooBig(size),
    );
  }

  return (
    items: [
      MediaAttachment(
        id: _uuid.v4(),
        type: 'document',
        sourcePath: path,
        sourceMime: mime,
        sourceBytes: size,
        fileName: name,
      ),
    ],
    problem: null,
  );
}

/// Turn picked XFiles into attachments, rejecting anything Meta will not take.
///
/// Video is checked here and NOT transcoded: there is no client-side transcode
/// available in 2026. `ffmpeg_kit_flutter` was retired in January 2025 and its
/// binaries were pulled from Maven Central and CocoaPods that April, so adding
/// it fails dependency resolution; `media_kit` decodes but does not encode. A
/// clear rejection is the honest state of the ecosystem, and it beats a silent
/// failure by a mile.
Future<_PickResult> _fromPicked(List<XFile> files) async {
  final out = <MediaAttachment>[];
  final rejected = <String>[];

  for (final file in files) {
    final path = file.path;
    final size = await File(path).length();
    final mime = file.mimeType ?? mimeForExtension(file.name) ?? '';
    final isVideo =
        mime.startsWith('video/') ||
        const {'mp4', '3gp', 'mov', 'm4v', 'avi', 'mkv'}.contains(
          path.split('.').last.toLowerCase(),
        );

    if (isVideo) {
      if (size > MetaLimits.video) {
        rejected.add(MediaMessages.videoTooBig(size));
        continue;
      }
      // Only mp4 and 3gpp are accepted. `image_picker_ios` saves the asset with
      // its original extension and attaches NO mimeType, so every clip off an
      // iPhone camera roll arrives as `IMG_xxxx.MOV` — H.264 or HEVC in a
      // QuickTime container, which Meta refuses with 131053.
      //
      // ⚠️ THIS MEANS OUTBOUND VIDEO IS UNAVAILABLE ON iOS, and no client-side
      // transcode exists to fix it (ffmpeg_kit_flutter was retired in 2025 and
      // its binaries were pulled; media_kit decodes but does not encode). The
      // proper fix is a server-side remux — `ffmpeg -i in.mov -c copy
      // -movflags +faststart out.mp4` is nearly free for the H.264 case — in its
      // own Cloud Function alongside transcodeVoiceNote, plus `video/quicktime`
      // in the `outbound/` clause of storage.rules. That is Phase 5.
      //
      // Until then the least we can do is not hand an iPhone owner an
      // instruction their phone cannot follow.
      final videoMime = mimeForExtension(file.name) ?? mime;
      if (!MetaLimits.videoMimes.contains(baseMime(videoMime))) {
        rejected.add(
          MediaMessages.videoFormat(
            isApple:
                defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.macOS,
          ),
        );
        continue;
      }
      out.add(
        MediaAttachment(
          id: _uuid.v4(),
          type: 'video',
          sourcePath: path,
          sourceMime: baseMime(videoMime),
          sourceBytes: size,
          fileName: file.name,
        ),
      );
      continue;
    }

    out.add(
      MediaAttachment(
        id: _uuid.v4(),
        type: 'image',
        sourcePath: path,
        sourceMime: mime.isEmpty ? null : mime,
        sourceBytes: size,
        fileName: file.name,
      ),
    );
  }

  return (items: out, problem: rejected.isEmpty ? null : rejected.first);
}

/// Compress one attachment, in place. Called the instant an item is picked, so
/// the bytes are ready long before a caption has been typed.
Future<void> prepareAttachment(MediaAttachment item) async {
  if (item.type != 'image') return;
  if (item.prepared != null || item.error != null) return;

  try {
    final result = await toChatJpeg(
      File(item.sourcePath),
      // ⚠️ Not optional in practice. Without it `baseMime(null)` is '' inside
      // compress.dart and every branch there that names a source format is dead
      // code — which is how every PNG ended up re-encoded as JPEG, blocking
      // around the digits of a rate list and turning a transparent cut-out's
      // background solid black.
      sourceMime: item.sourceMime,
    );
    if (result.bytes.length > MetaLimits.image) {
      item.error = MediaMessages.imageTooBig;
      return;
    }

    // Write the compressed bytes next to the original so the upload can stream
    // from disk rather than holding another copy in the Dart heap. Ten photos
    // at 350 KB is 3.5 MB of heap that has no reason to exist.
    final target = File(
      '${item.sourcePath}.akn.${extForMime(result.mime)}',
    );
    await target.writeAsBytes(result.bytes, flush: true);

    item.prepared = PreparedMedia(
      file: target,
      mime: result.mime,
      bytes: result.bytes.length,
      width: result.width,
      height: result.height,
      encoded: result.bytes,
    );
  } on CompressFailure catch (e) {
    debugPrint('compress failed: $e');
    // Temporarily carries the technical reason. Remote log capture does not
    // work over a wireless device connection, so when a photo will not send the
    // only way to learn WHY is to put it in front of the person holding the
    // phone. Revert to the plain message once media has been stable for a week.
    item.error = '${MediaMessages.unsupportedImage} [${e.message}]';
  } catch (e) {
    debugPrint('compress threw: $e');
    item.error = '${MediaMessages.compressionFailed} [$e]';
  }
}

class _AttachOption extends StatelessWidget {
  const _AttachOption({
    required this.icon,
    required this.label,
    required this.colour,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
              child: Icon(icon, size: 27, color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    ),
  );
}
