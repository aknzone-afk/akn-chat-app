import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/media/media_limits.dart';
import 'message.dart';

/// One picked item on its way to the caption screen and then to WhatsApp.
///
/// It is mutable in exactly one direction: [prepared] starts null and is filled
/// in when compression finishes. That is why compression can start the instant
/// an item is picked rather than when send is tapped — by the time a caption
/// has been typed the bytes are almost always ready, so the send is instant.
class MediaAttachment {
  MediaAttachment({
    required this.id,
    required this.type,
    required this.sourcePath,
    required this.sourceMime,
    required this.sourceBytes,
    this.fileName,
    this.caption = '',
  });

  /// Stable across the caption screen's PageView and filmstrip.
  final String id;

  /// image | video | document
  final String type;

  /// Where the picker put it on this phone.
  final String sourcePath;

  /// What the picker CLAIMED it is. Never trusted for images — an iPhone hands
  /// back `.heic`, which Meta rejects outright.
  final String? sourceMime;

  final int sourceBytes;
  final String? fileName;

  String caption;

  /// Set once compression finishes. Null means "still working" for an image,
  /// and "nothing to do" for video and documents (see [ready]).
  PreparedMedia? prepared;

  /// Set if preparation failed — shown on the item, not as a dead send button.
  String? error;

  /// Videos and documents are never transformed, so they are ready the moment
  /// they are picked. Only images have to wait.
  bool get ready => type != 'image' || prepared != null || error != null;

  bool get failed => error != null;

  /// The bytes to upload, and the MIME to declare with them.
  PreparedMedia get upload =>
      prepared ??
      PreparedMedia(
        file: File(sourcePath),
        mime: sourceMime ?? mimeForExtension(fileName ?? sourcePath) ?? 'application/octet-stream',
        bytes: sourceBytes,
      );

  /// What the optimistic bubble paints while the upload runs.
  String get previewPath => prepared?.file.path ?? sourcePath;

  String get messageType => switch (type) {
    'image' => MsgType.image,
    'video' => MsgType.video,
    _ => MsgType.document,
  };
}

/// The bytes we are actually going to send, plus everything the draft document
/// needs to describe them.
@immutable
class PreparedMedia {
  const PreparedMedia({
    required this.file,
    required this.mime,
    required this.bytes,
    this.width,
    this.height,
    this.encoded,
  });

  final File file;
  final String mime;
  final int bytes;
  final int? width;
  final int? height;

  /// The compressed bytes, kept only for images and only until the upload
  /// finishes. They are used to seed the disk image cache under the storage
  /// path, so when the bubble later switches from `Image.file` to
  /// `CachedNetworkImage` the bytes are already there and it paints in the same
  /// frame instead of flashing.
  final Uint8List? encoded;
}
