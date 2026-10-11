import 'package:flutter/material.dart';

import '../../../domain/message.dart';

/// THE ONLY PLACE `mediaStatus` IS INTERPRETED.
///
/// There are SEVEN states, not two:
///   none | pending | downloading | stored | error | failed | expired
/// written across `functions/lib/normalize.js`, `functions/lib/media.js` and
/// `functions/handlers/reconcile.js`. Phase 3 learned the hard way what happens
/// when they get interpreted in more than one place (see the comment this
/// replaces in message_bubble.dart): an unhandled state fell through to
/// "Phase 4 me khulega", telling staff to wait for a viewer for a file whose
/// bytes reconcile.js had already given up on. Do not let them scatter again.
///
/// The row that is easiest to get wrong is `none` on an OUTBOUND message that
/// has a mediaPath: that is OUR OWN upload in flight. It is a real, reachable,
/// completely normal state — on this phone it means "uploading", and on the
/// other three it means "the sender's phone is still working on it". It must
/// never render as an error.
enum MediaPhase {
  /// Nothing to draw — the bytes are here.
  ready,

  /// Coming down from Meta, or going up to Storage.
  working,

  /// Stalled, but the backend is still retrying.
  stalled,

  /// Gone for good.
  dead,
}

/// Work out which of the four phases a message is in.
MediaPhase mediaPhaseOf(Message m) {
  switch (m.mediaStatus) {
    case 'pending':
    case 'downloading':
      return MediaPhase.working;
    case 'error':
      return MediaPhase.stalled;
    case 'failed':
    case 'expired':
      return MediaPhase.dead;
    case 'stored':
      // "stored" means one thing and one thing only: THE BYTES ARE IN OUR
      // BUCKET, and `mediaPath` says where. `mediaUrl` is a convenience on top
      // of that — a CDN URL the backend mints best-effort — and gating on it was
      // a trap with no way out: minting one is a metadata write against GCS, so
      // a single transient failure left `stored` + null URL, which read as
      // "still arriving" and spun for ever on all four phones. reconcile.js
      // looks only at pending/downloading/error/failed and would never have seen
      // it. The widgets fall back to loading the object by path (storage.rules
      // grants staff read on wa-media/), so a path is enough to be ready.
      return m.mediaUrl == null && m.localPath == null && m.mediaPath == null
          ? MediaPhase.working
          : MediaPhase.ready;
  }
  // 'none' or missing.
  if (m.isOutgoing && (m.mediaPath != null || m.localPath != null)) {
    // Our own send. Ready only once there is something to actually paint.
    return (m.mediaUrl != null || m.localPath != null)
        ? MediaPhase.ready
        : MediaPhase.working;
  }
  return MediaPhase.ready;
}

/// The line of text under a document tile or beside a stalled photo.
String? mediaStatusLabel(Message m) {
  switch (mediaPhaseOf(m)) {
    case MediaPhase.ready:
      return null;
    case MediaPhase.working:
      // "Being sent" for ours, "arriving" for theirs. On the other three
      // phones an outbound row in this state means the sender's handset is
      // still uploading — which is why it must not read as an error.
      return m.isOutgoing ? 'Bheja ja raha hai…' : 'Aa raha hai…';
    case MediaPhase.stalled:
      return 'Ruk gaya — dobara koshish ho rahi hai';
    case MediaPhase.dead:
      return m.mediaStatus == 'expired'
          ? 'WhatsApp ne file hata di'
          : 'File save nahi ho paayi';
  }
}

/// What floats on top of an image or video bubble.
///
/// Deliberately NOT offered as a retry button for inbound media: `reconcile.js`
/// owns those retries and `messages` is `allow update: if false`, so a tap here
/// could do nothing at all. Say so in the copy instead of offering a button the
/// backend would ignore.
class MediaStatusOverlay extends StatelessWidget {
  const MediaStatusOverlay({super.key, required this.message, this.progress});

  final Message message;

  /// 0–1 while this phone is uploading. Null otherwise.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final phase = mediaPhaseOf(message);
    final uploading = progress != null && progress! < 1;

    if (phase == MediaPhase.ready && !uploading) {
      return const SizedBox.shrink();
    }

    final label = uploading ? null : mediaStatusLabel(message);

    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: phase == MediaPhase.ready ? 0.18 : 0.34),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Glyph(phase: phase, progress: progress),
                if (label != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Color(0x99000000), blurRadius: 3),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.phase, this.progress});

  final MediaPhase phase;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    if (progress != null && progress! < 1) {
      return SizedBox(
        width: 42,
        height: 42,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              // A determinate ring: staff can see a 4 MB photo actually moving,
              // which on a warehouse 4G connection is the difference between
              // "it is working" and "it is stuck".
              value: progress,
              strokeWidth: 2.6,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
            Text(
              '${(progress! * 100).round()}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );
    }

    return switch (phase) {
      MediaPhase.working || MediaPhase.ready => const SizedBox(
        width: 34,
        height: 34,
        child: CircularProgressIndicator(
          strokeWidth: 2.6,
          valueColor: AlwaysStoppedAnimation(Colors.white),
        ),
      ),
      MediaPhase.stalled => const Icon(
        Icons.hourglass_bottom_rounded,
        size: 34,
        color: Colors.white,
      ),
      MediaPhase.dead => const Icon(
        Icons.broken_image_outlined,
        size: 34,
        color: Colors.white,
      ),
    };
  }
}
