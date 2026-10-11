import 'package:flutter/foundation.dart';

import 'message.dart';

/// One page of the full-screen swipe gallery.
///
/// Deliberately flat and cheap: the gallery is rebuilt from
/// `chatSnapshotProvider` whenever the chat changes, so this must not hold
/// anything expensive or anything that has to be disposed.
@immutable
class MediaItem {
  const MediaItem({
    required this.messageId,
    required this.isVideo,
    required this.url,
    required this.cacheKey,
    required this.timestamp,
    required this.isOutgoing,
    this.localPath,
    this.caption,
    this.aspect,
  });

  factory MediaItem.from(Message m) => MediaItem(
    messageId: m.id,
    isVideo: m.type == MsgType.video,
    url: m.mediaUrl,
    // The STORAGE PATH, never the URL. Firebase download URLs carry a rotatable
    // `token` query parameter, so a URL-keyed cache re-downloads the whole
    // object every time that token changes.
    cacheKey: m.mediaPath ?? m.id,
    timestamp: m.timestamp,
    isOutgoing: m.isOutgoing,
    localPath: m.localPath,
    caption: m.caption,
    aspect: (m.mediaWidth != null && m.mediaHeight != null)
        ? m.mediaAspect
        : null,
  );

  final String messageId;
  final bool isVideo;

  /// Null only for an item that is still uploading from this phone, where
  /// [localPath] is what to paint.
  final String? url;

  final String cacheKey;
  final DateTime timestamp;
  final bool isOutgoing;
  final String? localPath;
  final String? caption;
  final double? aspect;

  /// Namespaced by MESSAGE id, never by URL. The same photo can legitimately
  /// appear twice on one screen (a bubble plus a future media strip), and
  /// duplicate Hero tags throw "multiple heroes share the same tag".
  String get heroTag => 'media_$messageId';

  bool get hasSource => url != null || localPath != null;

  @override
  bool operator ==(Object other) =>
      other is MediaItem &&
      other.messageId == messageId &&
      other.url == url &&
      other.localPath == localPath &&
      other.caption == caption;

  @override
  int get hashCode => Object.hash(messageId, url, localPath, caption);
}
