import 'dart:async';
import '../../../core/media/app_image_cache.dart';

import 'package:firebase_storage/firebase_storage.dart';

import '../../../core/media/media_limits.dart';
import '../domain/media_attachment.dart';

/// Puts a picked file into `outbound/{phoneNumberId}/{waId}/{objectName}` and
/// reports progress while it goes.
///
/// The object path shape is not decorative: `storage.rules` matches on it
/// exactly, and `sendMessage.js` re-validates it with a regex before it will
/// read a single byte — because the Admin SDK bypasses storage.rules entirely,
/// so that regex is the only thing standing between a staff login and every
/// object in the bucket, including other customers' raw webhook payloads in
/// `webhook-overflow/`.
class MediaUploader {
  const MediaUploader();

  /// Never the customer's own file name. It is hostile input, it can contain
  /// path separators, and `storage.rules` bounds the last segment at 200
  /// characters — so the object is named after the message id we generated and
  /// the MIME we are declaring. The real name survives in `fileName` on the
  /// document, which is what WhatsApp shows the recipient.
  static String objectPath({
    required String phoneNumberId,
    required String waId,
    required String messageId,
    required String mime,
  // `waId` may be a chat key (`<number>_<phoneNumberId>`); the folder is the
  // customer's number, because the path already names our business number.
  }) => 'outbound/$phoneNumberId/${waId.split('_').first}/$messageId.${extForMime(mime)}';

  /// Uploads and returns the storage path. Progress arrives on [onProgress] as
  /// 0–1.
  ///
  /// Throws whatever `firebase_storage` throws; the caller turns it into one of
  /// the Hinglish strings in [MediaMessages].
  Future<String> upload({
    required PreparedMedia media,
    required String phoneNumberId,
    required String waId,
    required String messageId,
    void Function(double progress)? onProgress,
  }) async {
    final path = objectPath(
      phoneNumberId: phoneNumberId,
      waId: waId,
      messageId: messageId,
      mime: media.mime,
    );

    final task = FirebaseStorage.instance.ref(path).putFile(
      media.file,
      SettableMetadata(
        // ⚠️ contentType is load-bearing three times over: storage.rules
        // matches on it, sendMessage.js falls back to it when the draft has no
        // mediaMime, and if it were left unset GCS would default the object to
        // `application/octet-stream` — which Meta rejects with 131053.
        contentType: media.mime,
        cacheControl: 'private, max-age=31536000, immutable',
      ),
    );

    StreamSubscription<TaskSnapshot>? sub;
    if (onProgress != null) {
      sub = task.snapshotEvents.listen(
        (snap) {
          if (snap.totalBytes <= 0) return;
          onProgress(snap.bytesTransferred / snap.totalBytes);
        },
        // The task's own future carries the real error; an unhandled one here
        // would surface as an unhandled async error and get blamed on whatever
        // ran next.
        onError: (Object _) {},
      );
    }

    try {
      await task;
    } finally {
      await sub?.cancel();
    }

    // Seed the disk image cache under the SAME key the network widget will use
    // later. When `mediaUrl` lands and the bubble switches from `Image.file` to
    // `CachedNetworkImage`, the bytes are already on disk and it paints in the
    // same frame. Without this the handover flashes — the photo the staff
    // member just sent blinks grey for a frame or two. Best effort only.
    final encoded = media.encoded;
    if (encoded != null) {
      try {
        await appImageCache.putFile(
          path,
          encoded,
          key: path,
          fileExtension: extForMime(media.mime),
        );
      } catch (_) {
        // A cold cache costs one network fetch. Never worth failing a send for.
      }
    }

    return path;
  }
}

const mediaUploader = MediaUploader();
