import 'package:cloud_firestore/cloud_firestore.dart';

/// The delivery tick on a message WE sent.
///
/// The backend stores a *rank*, not a state machine —
/// `sending 0 < sent 1 < delivered 2 < read 3 < played 4`, and `failed = 99` —
/// and only ever writes a status whose rank is higher than what is stored.
/// That is what makes Meta's retries and out-of-order webhooks free no-ops,
/// and why a red "!" can never quietly turn back into a tick.
enum Tick { none, sending, sent, delivered, read, played, failed }

/// Everything the app may render. Inbound messages arrive in every one of
/// these types today; the composer only *sends* text in Phase 3.
abstract final class MsgType {
  static const text = 'text';
  static const image = 'image';
  static const video = 'video';
  static const document = 'document';
  static const audio = 'audio';
  static const sticker = 'sticker';
  static const reaction = 'reaction';
  static const location = 'location';
  static const contacts = 'contacts';
  static const unknown = 'unknown';

  /// What `sendMessage` will accept and what firestore.rules allows on a draft.
  static const sendable = {text, image, video, document, audio};
}

class Message {
  const Message({
    required this.id,
    required this.direction,
    required this.type,
    required this.timestamp,
    this.from,
    this.text,
    this.caption,
    this.fileName,
    this.fileSize,
    this.mediaMime,
    this.mediaPath,
    this.mediaUrl,
    this.mediaStatus,
    this.mediaWidth,
    this.mediaHeight,
    this.thumbUrl,
    this.thumbB64,
    this.audioUrl,
    this.audioPath,
    this.audioStatus,
    this.audioDurationMs,
    this.audioPeaks,
    this.animated = false,
    this.localPath,
    this.uploadProgress,
    this.wamid,
    this.status,
    this.statusRank,
    this.replyToWamid,
    this.senderStaffId,
    this.phoneNumberId,
    this.botTurnId,
    this.botTemplateId,
    this.error,
    this.voice = false,
    this.forwarded = false,
    this.reactionRemoved = false,
    this.locationName,
    this.contactName,
    this.tapUrl,
    this.pendingWrite = false,
    this.localFailure,
    this.isGhost = false,
  });

  final String id;

  /// "in" | "out"
  final String direction;
  final String type;
  final DateTime timestamp;

  /// "customer" | "bot" | "staff" | "owner-cmd"
  final String? from;

  final String? text;
  final String? caption;
  final String? fileName;
  final int? fileSize;
  final String? mediaMime;
  final String? mediaPath;

  /// A stable Firebase download URL for the bytes.
  ///
  /// `lib/media.js` has always written this for inbound media; Phase 4's
  /// `sendMessage.js` writes it for our own sends too, which is what lets the
  /// other three phones render a photo this phone attached.
  final String? mediaUrl;

  /// none | pending | downloading | stored | error | failed | expired
  final String? mediaStatus;

  /// Pixel dimensions, so the bubble can reserve the right sized box BEFORE the
  /// bytes arrive. Without them the conversation reflows under the reader's
  /// thumb every time a photo lands.
  final int? mediaWidth;
  final int? mediaHeight;

  /// Server-made preview (functions/handlers/thumbs.js, 4-Oct-2026): a ~720 px
  /// JPEG for the bubble, so the chat never downloads the 1-2 MB original.
  final String? thumbUrl;

  /// ~24 px blurred JPEG as base64 (<1 KB) — painted instantly, like WhatsApp.
  final String? thumbB64;

  /// The iOS-playable transcode of a voice note. iOS AVFoundation has no Ogg
  /// demuxer, so for an `audio/ogg` message this — not [mediaUrl] — is what
  /// actually plays on an iPhone. See functions/handlers/transcodeVoiceNote.js.
  final String? audioUrl;
  final String? audioPath;

  /// pending | working | done | failed — absent entirely on non-ogg audio.
  final String? audioStatus;

  final int? audioDurationMs;

  /// 40 real RMS levels, 0–100. Not a decorative fake.
  final List<int>? audioPeaks;

  /// Animated sticker.
  final bool animated;

  /// Only ever set on an optimistic row: the file on THIS phone that is being
  /// uploaded right now. Lets the bubble paint the real photo instantly instead
  /// of a grey box.
  final String? localPath;

  /// 0–1 while our own upload is in flight, null otherwise.
  final double? uploadProgress;

  final String? wamid;
  final String? status;
  final int? statusRank;
  final String? replyToWamid;
  final String? senderStaffId;

  /// Which of OUR business numbers this message belongs to. Every inbound
  /// message carries it, and `sendMessage.js` stamps it on outbound ones — so
  /// it is the fallback for building an upload path when the chat document has
  /// not arrived yet.
  final String? phoneNumberId;

  /// Phase 5. On a bot message, the id of the INBOUND message that caused it —
  /// which is also the `bot_logs` document id. It is what makes the long-press
  /// "Ye reply kyun?" sheet a single doc().get() with no index.
  final String? botTurnId;

  /// Which template rendered it: DESIGN_PRICE, BILL_QUEUED, GREETING, COMPOSED…
  final String? botTemplateId;

  final Map<String, dynamic>? error;

  final bool voice;
  final bool forwarded;
  final bool reactionRemoved;
  final String? locationName;
  final String? contactName;

  /// 11-Oct-2026: a location opens Google Maps, a contact card dials.
  final String? tapUrl;

  /// The local write has not been acknowledged by the server yet.
  final bool pendingWrite;

  /// Set by the client-side outbox when the `sendMessage` callable threw.
  ///
  /// firestore.rules says `messages: allow update: if false`, so the app
  /// **cannot** write `status: 'failed'` onto the document itself. The failure
  /// therefore lives beside the document, in memory, and is merged in here.
  final String? localFailure;

  /// A row that exists only in the outbox — the Firestore write itself was
  /// rejected, so Firestore rolled the local document back. Without this the
  /// bubble would simply vanish and staff would have no idea why.
  final bool isGhost;

  factory Message.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    final location = d['location'];
    final raw = d['raw'];

    return Message(
      id: snap.id,
      direction: (d['direction'] as String?) ?? 'in',
      type: (d['type'] as String?) ?? MsgType.unknown,
      timestamp: _date(d['timestamp']) ?? _date(d['createdAt']) ?? DateTime.now(),
      from: d['from'] as String?,
      text: d['text'] as String?,
      caption: d['caption'] as String?,
      fileName: d['fileName'] as String?,
      fileSize: _int(d['fileSize']),
      mediaMime: d['mediaMime'] as String?,
      mediaPath: d['mediaPath'] as String?,
      // NOT parsed before Phase 4 even though lib/media.js has always written
      // it — which is why every inbound photo rendered as a placeholder.
      mediaUrl: d['mediaUrl'] as String?,
      mediaStatus: d['mediaStatus'] as String?,
      mediaWidth: _int(d['mediaWidth']),
      mediaHeight: _int(d['mediaHeight']),
      thumbUrl: d['thumbUrl'] as String?,
      thumbB64: d['thumbB64'] as String?,
      audioUrl: d['audioUrl'] as String?,
      audioPath: d['audioPath'] as String?,
      audioStatus: d['audioStatus'] as String?,
      audioDurationMs: _int(d['audioDurationMs']),
      audioPeaks: _intList(d['audioPeaks']),
      animated: d['animated'] == true,
      wamid: d['wamid'] as String?,
      status: d['status'] as String?,
      statusRank: _int(d['statusRank']),
      replyToWamid: d['replyToWamid'] as String?,
      senderStaffId: d['senderStaffId'] as String?,
      phoneNumberId: d['phoneNumberId'] as String?,
      botTurnId: d['botTurnId'] as String?,
      botTemplateId: d['botTemplateId'] as String?,
      error: d['error'] is Map ? Map<String, dynamic>.from(d['error'] as Map) : null,
      voice: d['voice'] == true,
      forwarded: d['forwarded'] == true,
      reactionRemoved: d['reactionRemoved'] == true,
      locationName: location is Map
          ? (location['name'] as String?) ?? (location['address'] as String?)
          : null,
      contactName: raw is Map ? _firstContactName(raw) : null,
      tapUrl: _tapUrl(location, raw),
      pendingWrite: snap.metadata.hasPendingWrites,
    );
  }

  bool get isOutgoing => direction == 'out';
  bool get isReaction => type == MsgType.reaction;

  /// The text a bubble actually shows for a text message.
  String get body => (text ?? '').trim();

  Message copyWith({
    String? localFailure,
    bool clearLocalFailure = false,
    String? localPath,
    double? uploadProgress,
  }) => Message(
    id: id,
    direction: direction,
    type: type,
    timestamp: timestamp,
    from: from,
    text: text,
    caption: caption,
    fileName: fileName,
    fileSize: fileSize,
    mediaMime: mediaMime,
    mediaPath: mediaPath,
    mediaUrl: mediaUrl,
    mediaStatus: mediaStatus,
    mediaWidth: mediaWidth,
    mediaHeight: mediaHeight,
    thumbUrl: thumbUrl,
    thumbB64: thumbB64,
    audioUrl: audioUrl,
    audioPath: audioPath,
    audioStatus: audioStatus,
    audioDurationMs: audioDurationMs,
    audioPeaks: audioPeaks,
    animated: animated,
    localPath: localPath ?? this.localPath,
    uploadProgress: uploadProgress ?? this.uploadProgress,
    wamid: wamid,
    status: status,
    statusRank: statusRank,
    replyToWamid: replyToWamid,
    senderStaffId: senderStaffId,
    phoneNumberId: phoneNumberId,
    botTurnId: botTurnId,
    botTemplateId: botTemplateId,
    error: error,
    voice: voice,
    forwarded: forwarded,
    reactionRemoved: reactionRemoved,
    locationName: locationName,
    contactName: contactName,
    tapUrl: tapUrl,
    pendingWrite: pendingWrite,
    localFailure: clearLocalFailure ? null : (localFailure ?? this.localFailure),
    isGhost: isGhost,
  );

  /// A row that lives only in the outbox: either Firestore has not echoed the
  /// draft back over the platform channel yet, or it refused the write outright
  /// and rolled the local document back.
  factory Message.optimistic({
    required String id,
    required String body,
    required DateTime at,
    String? replyToWamid,
    String? failure,
  }) => Message(
    id: id,
    direction: 'out',
    type: MsgType.text,
    timestamp: at,
    from: 'staff',
    text: body,
    status: failure == null ? 'sending' : 'failed',
    statusRank: failure == null ? 0 : 99,
    replyToWamid: replyToWamid,
    localFailure: failure,
    isGhost: true,
  );

  /// The same thing for a photo, video or document we are sending.
  ///
  /// [localPath] is the whole point: the bubble paints the real image off the
  /// phone's own disk from the very first frame, at the right aspect ratio
  /// (we know it — compression measured it), with a progress ring on top.
  /// Nobody ever sees a grey box for their own photo.
  factory Message.optimisticMedia({
    required String id,
    required String type,
    required DateTime at,
    required String localPath,
    String? caption,
    String? mime,
    String? fileName,
    int? fileSize,
    int? width,
    int? height,
    double? progress,
    String? replyToWamid,
    String? failure,
  }) => Message(
    id: id,
    direction: 'out',
    type: type,
    timestamp: at,
    from: 'staff',
    caption: (caption == null || caption.isEmpty) ? null : caption,
    fileName: fileName,
    fileSize: fileSize,
    mediaMime: mime,
    mediaWidth: width,
    mediaHeight: height,
    localPath: localPath,
    uploadProgress: progress,
    // 'none' is deliberate and it is a REAL, reachable state: our own upload is
    // in flight and there is nothing in Storage yet. media_status_overlay.dart
    // renders it as progress, never as an error.
    mediaStatus: 'none',
    status: failure == null ? 'sending' : 'failed',
    statusRank: failure == null ? 0 : 99,
    replyToWamid: replyToWamid,
    localFailure: failure,
    isGhost: true,
  );

  // -------------------------------------------------------------------------
  // Media helpers
  // -------------------------------------------------------------------------

  bool get isMedia =>
      type == MsgType.image ||
      type == MsgType.video ||
      type == MsgType.document ||
      type == MsgType.audio ||
      type == MsgType.sticker;

  /// Can this one appear in the full-screen swipe gallery?
  bool get isViewableMedia =>
      (type == MsgType.image || type == MsgType.video) &&
      (mediaUrl != null || localPath != null);

  /// True while the bytes are on their way from Meta to our bucket.
  bool get mediaArriving =>
      mediaStatus == 'pending' || mediaStatus == 'downloading';

  /// True when the bytes are gone for good and no retry will bring them back.
  bool get mediaDead => mediaStatus == 'failed' || mediaStatus == 'expired';

  /// True when the bytes are really there.
  bool get mediaReady => mediaStatus == 'stored' && mediaUrl != null;

  /// What `just_audio` should actually play.
  ///
  /// The transcode first: a WhatsApp voice note is `audio/ogg; codecs=opus`, and
  /// iOS has no Ogg demuxer at all, so on an iPhone the original is not merely
  /// slow — it does not play. On Android either works.
  String? get playableAudioUrl => audioUrl ?? mediaUrl;

  /// The aspect ratio to reserve for an image or video bubble. Portrait by
  /// default, because sarees are shot vertical.
  double get mediaAspect {
    final w = mediaWidth;
    final h = mediaHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return 3 / 4;
    return w / h;
  }

  /// Ticks are for outgoing messages only — an inbound message never has one.
  Tick tickAt(DateTime now) {
    if (!isOutgoing) return Tick.none;
    if (localFailure != null) return Tick.failed;
    if (status == 'failed' || (statusRank ?? 0) >= 99) return Tick.failed;

    switch (statusRank) {
      case 4:
        return Tick.played;
      case 3:
        return Tick.read;
      case 2:
        return Tick.delivered;
      case 1:
        return Tick.sent;
    }

    // statusRank 0 / null → still 'sending'. If it has been sitting there for
    // more than 90 seconds, the send almost certainly died with the app (the
    // callable never returned, or the phone was killed mid-flight). Show it as
    // retryable rather than as a clock that spins for ever.
    if (now.difference(timestamp) > const Duration(seconds: 90)) {
      return Tick.failed;
    }
    return Tick.sending;
  }

  /// Can THIS phone's user tap "Dobara bhejein" and have it work?
  ///
  /// Two separate gates, and both matter on a four-phone product:
  ///
  ///  * `wamid == null` — Meta already has anything that carries a wamid, so
  ///    `sendMessage` answers `already-sent` and a retry is a no-op.
  ///  * the draft is ours — `sendMessage.js` refuses a claim when
  ///    `doc.senderStaffId !== staff.uid` ("Somebody else wrote that draft")
  ///    and returns `permission-denied`, which is indistinguishable at the call
  ///    site from "you are not staff". Offering the tap to the other three
  ///    phones means offering them a button that tells them their account has
  ///    been deactivated.
  bool isRetryableBy(String? uid) =>
      isOutgoing &&
      wamid == null &&
      (senderStaffId == null || senderStaffId == uid);

  /// An `unknown` document that still carries readable text.
  ///
  /// normalize.js stores a system notice ("the customer changed their WhatsApp
  /// number"), a template button tap and an interactive reply as
  /// `type: "unknown"` while deliberately keeping the human-readable line in
  /// `text`. Painting "app abhi nahi dikha sakta" over real text — on the one
  /// event the backend flags `needsAttention` — is worse than an unstyled
  /// bubble, and it contradicts the chat-list preview one screen back.
  bool get rendersAsText =>
      type == MsgType.text || (type == MsgType.unknown && body.isNotEmpty);

  /// The one-line stand-in for a media message. Since Phase 4 the bubbles
  /// render the real thing, so this survives only for the chat-list preview,
  /// the quoted-reply box, and the three types that still have no viewer
  /// (location, contacts, unknown).
  String get placeholder => switch (type) {
    MsgType.image => '📷 Photo',
    MsgType.video => '🎥 Video',
    MsgType.document => '📄 ${fileName ?? 'Document'}',
    MsgType.audio => voice ? '🎤 Voice message' : '🎵 Audio',
    MsgType.sticker => '😀 Sticker',
    MsgType.location => '📍 ${locationName ?? 'Location'}',
    MsgType.contacts => '👤 ${contactName ?? 'Contact card'}',
    MsgType.unknown => '⚠️ Ye message app abhi nahi dikha sakta',
    _ => '⚠️ Message',
  };

  /// Short label used inside a quoted reply box and the chat-list preview.
  String get shortPreview {
    if (rendersAsText) {
      final b = body;
      return b.isEmpty ? 'Message' : b;
    }
    final c = caption?.trim();
    if (c != null && c.isNotEmpty) return c;
    return placeholder;
  }

  /// ⚠️ `mediaUrl` and `audioUrl` are in here on purpose, and leaving them out
  /// is a real bug rather than an optimisation.
  ///
  /// For INBOUND media it happens to work without them: `mediaStatus` and
  /// `mediaUrl` flip in the same `ref.update()`, so the status change alone
  /// repaints the bubble. For OUTBOUND media it does not — `sendMessage.js`
  /// writes `mediaStatus: 'stored'` and the URL together, but the row was
  /// already `'none'`… and for the voice-note transcode, `audioUrl` lands with
  /// no `mediaStatus` change at all. A bubble that never repaints when its URL
  /// arrives is a photo that stays grey for ever on the other three phones.
  @override
  bool operator ==(Object other) =>
      other is Message &&
      other.id == id &&
      other.type == type &&
      other.text == text &&
      other.caption == caption &&
      other.status == status &&
      other.statusRank == statusRank &&
      other.wamid == wamid &&
      other.timestamp == timestamp &&
      other.mediaStatus == mediaStatus &&
      other.mediaUrl == mediaUrl &&
      other.thumbUrl == thumbUrl &&
      other.mediaWidth == mediaWidth &&
      other.mediaHeight == mediaHeight &&
      other.audioUrl == audioUrl &&
      other.audioStatus == audioStatus &&
      other.audioDurationMs == audioDurationMs &&
      other.localPath == localPath &&
      other.uploadProgress == uploadProgress &&
      other.pendingWrite == pendingWrite &&
      other.localFailure == localFailure &&
      other.isGhost == isGhost;

  @override
  int get hashCode => Object.hash(
    id,
    type,
    text,
    caption,
    status,
    statusRank,
    wamid,
    timestamp,
    mediaStatus,
    mediaUrl,
    Object.hash(mediaWidth, mediaHeight, audioUrl, audioStatus, thumbUrl),
    Object.hash(audioDurationMs, localPath, uploadProgress),
    pendingWrite,
    localFailure,
    isGhost,
  );
}

String? _tapUrl(Object? location, Object? raw) {
  final loc = location is Map ? location : (raw is Map ? raw['location'] : null);
  if (loc is Map && loc['latitude'] != null && loc['longitude'] != null) {
    return 'https://maps.google.com/?q=${loc['latitude']},${loc['longitude']}';
  }
  final contacts = raw is Map ? raw['contacts'] : null;
  if (contacts is List && contacts.isNotEmpty && contacts.first is Map) {
    final phones = (contacts.first as Map)['phones'];
    if (phones is List && phones.isNotEmpty && phones.first is Map) {
      final ph = ((phones.first as Map)['phone'] as String?)?.replaceAll(RegExp(r'[^0-9+]'), '');
      if (ph != null && ph.isNotEmpty) return 'tel:$ph';
    }
  }
  return null;
}

String? _firstContactName(Map raw) {
  final contacts = raw['contacts'];
  if (contacts is List && contacts.isNotEmpty) {
    final first = contacts.first;
    if (first is Map && first['name'] is Map) {
      return (first['name'] as Map)['formatted_name'] as String?;
    }
  }
  return null;
}

DateTime? _date(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

/// The waveform. Firestore hands back `List<dynamic>`, and the numbers may come
/// through as `int` or `double` depending on how they were written, so this is
/// deliberately forgiving — a malformed peaks array must draw a flat bar, never
/// throw inside a painter.
List<int>? _intList(Object? v) {
  if (v is! List || v.isEmpty) return null;
  final out = <int>[];
  for (final item in v) {
    if (item is num) {
      out.add(item.toInt().clamp(0, 100));
    } else {
      out.add(0);
    }
  }
  return out;
}

/// Human file size for the document placeholder.
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
}
