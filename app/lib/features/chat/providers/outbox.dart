import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message.dart';

enum OutboxState {
  inFlight,
  failed,

  /// The send succeeded and the document's own `statusRank` owns the tick from
  /// here — but the entry is kept a moment longer, purely so its `localPath`
  /// keeps feeding the bubble.
  ///
  /// Without this state there is a window with nothing to paint. `mediaUrl` is
  /// written by `sendMessage.js` and reaches this phone over the Firestore
  /// LISTENER, which is a different channel from the callable's HTTP response
  /// with no ordering guarantee between them. Clearing the entry the instant the
  /// callable returned dropped `localPath` while `mediaUrl` was still in flight,
  /// so the row had neither a local file nor a URL and the photo the staff
  /// member had just watched upload blinked to a grey box with a spinner on it.
  settled,
}

/// A message the app has handed to the backend but has not seen succeed.
///
/// This exists because of one line in firestore.rules:
///
///     match /chats/{waId}/messages/{messageId} {
///       allow update, delete: if false;
///     }
///
/// The textbook optimistic-send rollback — delete the draft, or write
/// `status: 'failed'` onto it — is therefore impossible from a phone. The
/// failure has to live *beside* the document, in memory, and be merged into the
/// row at render time. That is all this is.
///
/// PHASE 4 added a media block. One class with a nullable media block rather
/// than a sealed hierarchy, deliberately: `chatSnapshotProvider`'s merge loop
/// stays a single loop, and the only thing that changes there is which
/// `Message` factory it calls.
@immutable
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.waId,
    required this.body,
    required this.at,
    required this.state,
    this.replyToWamid,
    this.error,
    this.docRolledBack = false,
    this.type = MsgType.text,
    this.localPath,
    this.mime,
    this.fileName,
    this.fileSize,
    this.width,
    this.height,
    this.caption,
    this.progress = 0,
    this.uploaded = false,
    this.drafted = false,
    this.mediaPath,
  });

  /// A photo / video / document send.
  const OutboxEntry.media({
    required this.id,
    required this.waId,
    required this.at,
    required this.state,
    required this.type,
    required this.localPath,
    required this.mime,
    this.fileName,
    this.fileSize,
    this.width,
    this.height,
    this.caption,
    this.replyToWamid,
    this.error,
    this.docRolledBack = false,
    this.progress = 0,
    this.uploaded = false,
    this.drafted = false,
    this.mediaPath,
  }) : body = '';

  final String id;
  final String waId;

  /// The text body. Empty for a media entry.
  final String body;

  final DateTime at;
  final OutboxState state;
  final String? replyToWamid;
  final String? error;

  /// Firestore refused the write itself (a rules rejection), so it rolled the
  /// local document back and the bubble would otherwise simply vanish.
  final bool docRolledBack;

  // ---- the media block ----------------------------------------------------

  final String type;

  /// The file on THIS phone. What the optimistic bubble paints.
  final String? localPath;

  final String? mime;
  final String? fileName;
  final int? fileSize;
  final int? width;
  final int? height;
  final String? caption;

  /// 0–1. Deliberately in memory and NEVER on the document: a per-byte write to
  /// Firestore would be absurd, and it would drop client rows into
  /// reconcile.js's stuck-media sweep.
  final double progress;

  /// The bytes are in Storage.
  final bool uploaded;

  /// The draft document reached Firestore.
  final bool drafted;

  /// WHERE the bytes actually landed in Storage — `outbound/{pnid}/{waId}/…`.
  ///
  /// Set alongside [uploaded], and it is what makes a retry after a rolled-back
  /// draft possible at all. The ghost row cannot supply it: the optimistic
  /// `Message` has no `mediaPath` (there is no document to read one from), so
  /// the old retry path read `message.mediaPath`, always got null, and dropped
  /// into a dead branch. The bytes then sat in `outbound/` with no document
  /// pointing at them and no client able to delete them.
  final String? mediaPath;

  bool get isMedia => type != MsgType.text;

  OutboxEntry copyWith({
    OutboxState? state,
    String? error,
    bool? docRolledBack,
    double? progress,
    bool? uploaded,
    bool? drafted,
    String? mediaPath,
  }) => OutboxEntry(
    id: id,
    waId: waId,
    body: body,
    at: at,
    state: state ?? this.state,
    replyToWamid: replyToWamid,
    error: error ?? this.error,
    docRolledBack: docRolledBack ?? this.docRolledBack,
    type: type,
    localPath: localPath,
    mime: mime,
    fileName: fileName,
    fileSize: fileSize,
    width: width,
    height: height,
    caption: caption,
    progress: progress ?? this.progress,
    uploaded: uploaded ?? this.uploaded,
    drafted: drafted ?? this.drafted,
    mediaPath: mediaPath ?? this.mediaPath,
  );

  /// The optimistic row this entry renders as while there is no document yet.
  Message toOptimisticMessage() {
    final failure = state == OutboxState.failed
        ? (error ?? 'Message bheja nahi ja saka.')
        : null;

    if (!isMedia) {
      return Message.optimistic(
        id: id,
        body: body,
        at: at,
        replyToWamid: replyToWamid,
        failure: failure,
      );
    }

    return Message.optimisticMedia(
      id: id,
      type: type,
      at: at,
      localPath: localPath ?? '',
      caption: caption,
      mime: mime,
      fileName: fileName,
      fileSize: fileSize,
      width: width,
      height: height,
      progress: state == OutboxState.inFlight ? progress : null,
      replyToWamid: replyToWamid,
      failure: failure,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OutboxEntry &&
      other.id == id &&
      other.state == state &&
      other.error == error &&
      other.docRolledBack == docRolledBack &&
      other.progress == progress &&
      other.uploaded == uploaded &&
      other.drafted == drafted &&
      other.mediaPath == mediaPath;

  @override
  int get hashCode => Object.hash(
    id,
    state,
    error,
    docRolledBack,
    progress,
    uploaded,
    drafted,
    mediaPath,
  );
}

class Outbox extends Notifier<Map<String, OutboxEntry>> {
  @override
  Map<String, OutboxEntry> build() => const {};

  void enqueue(OutboxEntry entry) {
    state = {...state, entry.id: entry};
  }

  void markInFlight(String id) {
    final entry = state[id];
    if (entry == null) return;
    state = {
      ...state,
      id: entry.copyWith(state: OutboxState.inFlight, error: ''),
    };
  }

  void markFailed(String id, String error, {bool docRolledBack = false}) {
    final entry = state[id];
    if (entry == null) return;
    state = {
      ...state,
      id: entry.copyWith(
        state: OutboxState.failed,
        error: error,
        docRolledBack: docRolledBack,
      ),
    };
  }

  /// Upload progress, 0–1.
  ///
  /// Quantised to whole percent before it is compared, so a 4 MB upload
  /// notifies about a hundred times rather than once per chunk. Every notify
  /// here rebuilds `chatSnapshotProvider`, which rebuilds the merged list —
  /// this is the one place in Phase 4 that could quietly reintroduce a
  /// per-frame rebuild of the whole conversation.
  void setProgress(String id, double value) {
    final entry = state[id];
    if (entry == null) return;
    final next = (value.clamp(0.0, 1.0) * 100).roundToDouble() / 100;
    if (entry.progress == next) return;
    state = {...state, id: entry.copyWith(progress: next)};
  }

  /// The bytes are in Storage, at [mediaPath].
  ///
  /// The path is not optional: `retry()` needs it to rewrite a draft whose write
  /// was rejected, and there is nowhere else on this phone that knows it.
  void markUploaded(String id, String mediaPath) {
    final entry = state[id];
    if (entry == null) return;
    if (entry.uploaded && entry.mediaPath == mediaPath) return;
    state = {
      ...state,
      id: entry.copyWith(uploaded: true, progress: 1, mediaPath: mediaPath),
    };
  }

  void markDrafted(String id) {
    final entry = state[id];
    if (entry == null || entry.drafted) return;
    state = {...state, id: entry.copyWith(drafted: true)};
  }

  /// The send succeeded. The document's `statusRank` owns the tick from now on,
  /// but the entry lingers so its `localPath` keeps painting the bubble until
  /// `mediaUrl` arrives over the listener. See [OutboxState.settled].
  void markSettled(String id) {
    final entry = state[id];
    if (entry == null || entry.state == OutboxState.settled) return;
    state = {...state, id: entry.copyWith(state: OutboxState.settled)};
  }

  /// The send succeeded — the document's own `statusRank` is authoritative from
  /// here on, so the overlay must get out of the way.
  void clear(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }

  OutboxEntry? read(String id) => state[id];

  Iterable<OutboxEntry> forChat(String waId) =>
      state.values.where((e) => e.waId == waId);
}

final outboxProvider = NotifierProvider<Outbox, Map<String, OutboxEntry>>(
  Outbox.new,
);
