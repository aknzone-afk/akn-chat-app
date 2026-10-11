import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'media_limits.dart';

/// Longest edge of an outgoing photo.
///
/// 1600px at quality 82 measures 180–380 KB for a saree photograph — an order
/// of magnitude under Meta's 5 MB and visually indistinguishable from the
/// original at phone and laptop sizes.
const int kChatImageMaxEdge = 1600;

/// Do NOT drop below 78 for this business. Saree fabric is fine-detail texture
/// and JPEG blocking shows up in it long before it shows up in a face or a
/// landscape.
const int kChatImageQuality = 82;

/// The trick that makes a "no resize" pass work.
///
/// `flutter_image_compress` computes `scale = min(1.0, max(minW/srcW, minH/srcH))`
/// — so absurdly large minimums make the max() term huge, min() clamps it, and
/// scale comes out exactly 1.0.
const int _kNoResize = 1 << 20;

/// A photo that is ready to upload.
@immutable
class CompressedImage {
  const CompressedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.mime,
    required this.passthrough,
  });

  final Uint8List bytes;

  /// → `mediaWidth` / `mediaHeight` on the draft, so the bubble can reserve the
  /// right sized box before the upload finishes.
  final int width;
  final int height;

  /// Always `image/jpeg` or `image/png` — never whatever the source claimed.
  final String mime;

  /// True when we did not re-encode at all.
  final bool passthrough;

  int get bytesLength => bytes.length;
}

/// Thrown when an image genuinely cannot be prepared. The caller turns this
/// into one of the Hinglish strings in [MediaMessages].
class CompressFailure implements Exception {
  const CompressFailure(this.message);
  final String message;
  @override
  String toString() => 'CompressFailure: $message';
}

/// Normalises ANY input — including an iPhone HEIC — to an upright JPEG whose
/// LONGEST edge is at most [maxEdge], with EXIF orientation baked into the
/// pixels and the EXIF block stripped.
///
/// ---------------------------------------------------------------------------
/// THE `minWidth`/`minHeight` TRAP, because this is the part that gets
/// implemented wrong every time.
///
/// They are COVER bounds, not a bounding box. The implemented rule is
/// `scale = min(1.0, max(minWidth/srcW, minHeight/srcH))`, so passing
/// `minWidth: 1600, minHeight: 1600` caps the **shortest** edge at 1600 and
/// leaves a 4000×2000 photo at 3200×1600. The package's own README worked
/// example proves it (4000×2000 with 1920/1080 → 2160×1080, wider than 1920).
///
/// So this is TWO passes with a measurement in between:
///   1. transcode with no resize — this is what turns HEIC into JPEG and bakes
///      in the rotation;
///   2. read the dimensions off the now-baseline JPEG header (cheap: a header
///      read via `ui.ImageDescriptor`, not a full decode);
///   3. re-encode at the exact target dimensions we computed ourselves, where
///      the cover formula produces precisely `tw × th`.
/// ---------------------------------------------------------------------------
///
/// EXIF, definitively: `autoCorrectionAngle: true` + `keepExif: false` in pass
/// one, and `autoCorrectionAngle: false` (already applied) + `keepExif: false`
/// in pass two. **`keepExif: true` together with `autoCorrectionAngle: true` is
/// the sideways-photo bug** — the pixels get rotated AND the `Orientation` tag
/// survives, so WhatsApp rotates a second time. Stripping EXIF also drops GPS,
/// which is the right default for a business handling customer photos.
///
/// ---------------------------------------------------------------------------
/// PNG, and why [sourceMime] is not optional in practice.
///
/// It used to be passed nowhere, so `baseMime(null)` was `''` and every branch
/// below that names a source format was unreachable. The consequence was not
/// theoretical: **every PNG was re-encoded as JPEG.** A screenshot of the rate
/// list — the one image in this business whose entire content is sharp small
/// text — went to the customer with ringing artefacts around every digit, and a
/// cut-out product shot or a logo with an alpha channel came out on a SOLID
/// BLACK background, because `CompressFormat.jpeg` has nowhere to put alpha.
///
/// So a PNG source stays a PNG through BOTH passes. Pass 1 has to honour it too:
/// flattening to JPEG there and "keeping PNG" in pass 2 would re-wrap an already
/// destroyed image.
///
/// The one thing deliberately NOT restored is the JPEG passthrough. Returning
/// `src.readAsBytes()` returns the ORIGINAL EXIF block with it, GPS included,
/// which flatly contradicts the privacy promise three paragraphs up. One extra
/// generation at q82 is a cheaper price than a customer's home coordinates
/// riding along with a saree photo. PNG passthrough is safe because a PNG has no
/// EXIF GPS to leak.
/// ---------------------------------------------------------------------------
Future<CompressedImage> toChatJpeg(
  File src, {
  int maxEdge = kChatImageMaxEdge,
  int quality = kChatImageQuality,
  String? sourceMime,
}) async {
  final int sourceBytes;
  try {
    sourceBytes = await src.length();
  } catch (_) {
    throw const CompressFailure('source file is unreadable');
  }
  if (sourceBytes <= 0) throw const CompressFailure('source file is empty');

  final keepPng = baseMime(sourceMime) == 'image/png';
  final format = keepPng ? CompressFormat.png : CompressFormat.jpeg;
  final mime = keepPng ? 'image/png' : 'image/jpeg';

  // ---- Pass 1: transcode, no resize ---------------------------------------
  Uint8List? normalised;
  try {
    normalised = await FlutterImageCompress.compressWithFile(
      src.absolute.path,
      minWidth: _kNoResize,
      minHeight: _kNoResize,
      quality: 100,
      // JPEG for everything else, which is what turns an iPhone HEIC into
      // something Meta will accept.
      format: format,
      autoCorrectionAngle: true,
      keepExif: false,
    );
  } catch (e) {
    throw CompressFailure('transcode threw: $e');
  }
  if (normalised == null || normalised.isEmpty) {
    throw const CompressFailure('transcode produced no bytes');
  }

  // ---- Measure -------------------------------------------------------------
  final size = await _measure(normalised);
  if (size == null) throw const CompressFailure('could not read the dimensions');
  final (w, h) = size;

  final longest = w > h ? w : h;
  if (longest <= maxEdge) {
    // A PNG that is already small enough: send the original bytes untouched.
    // JPEG artefacts around text are ugly, the PNG is genuinely smaller, and on
    // iOS `quality` is IGNORED for PNG (ImageIO has no PNG quality knob), so
    // "compressing" it there does nothing but re-encode.
    if (keepPng && sourceBytes <= 1024 * 1024) {
      return CompressedImage(
        bytes: await src.readAsBytes(),
        width: w,
        height: h,
        mime: 'image/png',
        passthrough: true,
      );
    }

    // Small enough already — re-encode for size only, still no resize.
    final out = await FlutterImageCompress.compressWithList(
      normalised,
      minWidth: _kNoResize,
      minHeight: _kNoResize,
      quality: quality,
      format: format,
      autoCorrectionAngle: false,
      keepExif: false,
    );
    return _finish(
      out: out,
      normalised: normalised,
      width: w,
      height: h,
      targetWidth: _kNoResize,
      targetHeight: _kNoResize,
      quality: quality,
      keepPng: keepPng,
      mime: mime,
    );
  }

  // ---- Pass 2: exact target dimensions ------------------------------------
  final scale = maxEdge / longest;
  final tw = (w * scale).round().clamp(1, maxEdge);
  final th = (h * scale).round().clamp(1, maxEdge);

  final Uint8List out;
  try {
    out = await FlutterImageCompress.compressWithList(
      normalised,
      minWidth: tw,
      minHeight: th,
      quality: quality,
      format: format,
      autoCorrectionAngle: false,
      keepExif: false,
      // `inSampleSize` stays at 1: it is Android-only and the plugin already
      // picks a sane sample size from the target dimensions.
    );
  } catch (e) {
    throw CompressFailure('resize threw: $e');
  }
  if (out.isEmpty) throw const CompressFailure('resize produced no bytes');

  return _finish(
    out: out,
    normalised: normalised,
    width: tw,
    height: th,
    targetWidth: tw,
    targetHeight: th,
    quality: quality,
    keepPng: keepPng,
    mime: mime,
  );
}

/// Measure what we actually produced, and rescue the one case where keeping PNG
/// backfires.
///
/// A PHOTOGRAPHIC png — someone screenshots a photo, or shares a PNG export of
/// one — does not compress, and at 1600px it can land well over Meta's 5 MB
/// image cap. Keeping the format would then get the send rejected outright with
/// "Ye photo bahut badi hai", which is a worse outcome for the staff member than
/// a JPEG they cannot tell apart. Text and alpha are what PNG is being preserved
/// FOR, and neither survives being refused.
Future<CompressedImage> _finish({
  required Uint8List out,
  required Uint8List normalised,
  required int width,
  required int height,
  required int targetWidth,
  required int targetHeight,
  required int quality,
  required bool keepPng,
  required String mime,
}) async {
  if (out.isEmpty) throw const CompressFailure('re-encode produced no bytes');

  var bytes = out;
  var finalMime = mime;

  if (keepPng && bytes.length > MetaLimits.image) {
    try {
      final jpeg = await FlutterImageCompress.compressWithList(
        normalised,
        minWidth: targetWidth,
        minHeight: targetHeight,
        quality: quality,
        format: CompressFormat.jpeg,
        autoCorrectionAngle: false,
        keepExif: false,
      );
      if (jpeg.isNotEmpty) {
        bytes = jpeg;
        finalMime = 'image/jpeg';
      }
    } catch (_) {
      // Keep the oversized PNG; prepareAttachment turns it into a clear
      // "photo bahut badi hai" rather than a silent failure.
    }
  }

  // The re-encode may land a pixel either side of the request; measure what we
  // actually produced rather than trusting the arithmetic, because these numbers
  // become the bubble's aspect ratio.
  final actual = await _measure(bytes) ?? (width, height);

  return CompressedImage(
    bytes: bytes,
    width: actual.$1,
    height: actual.$2,
    mime: finalMime,
    passthrough: false,
  );
}

/// Reads width/height out of an encoded image's header. Not a full decode — no
/// 64 MB RGBA buffer is ever allocated.
Future<(int, int)?> _measure(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    if (w <= 0 || h <= 0) return null;
    return (w, h);
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
