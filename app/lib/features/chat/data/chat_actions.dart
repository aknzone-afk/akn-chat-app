import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/failure.dart';
import '../../../core/firebase/firebase_providers.dart';
import '../../../core/media/media_limits.dart';
import '../domain/media_attachment.dart';
import '../domain/message.dart';
import '../providers/chat_providers.dart';
import '../providers/outbox.dart';
import 'media_uploader.dart';

const _uuid = Uuid();

/// Meta allows ONE message per 6 seconds to the same WhatsApp user, with a
/// burst allowance of ~45 in 6 seconds that borrows against future quota;
/// exceeding it is error 131056. Ten photos to one customer in two seconds sits
/// inside the burst but drains it, so the callables are paced.
///
/// This is invisible to staff: the bubbles all appear instantly regardless.
/// The pacing is only on the network side.
const _perRecipientGap = Duration(milliseconds: 400);

/// How long we wait for the DRAFT write to reach the server before deciding
/// we are offline. Firestore's `set()` future does not complete at all while
/// offline — it waits for the server ack, for ever — so it can never be
/// awaited on a UI path without a deadline.
const _writeDeadline = Duration(seconds: 10);

final _linkPattern = RegExp(r'https?://', caseSensitive: false);

/// Every mutation the app is allowed to make, in one object.
///
/// Almost nothing here writes to Firestore. firestore.rules gives the app
/// exactly ONE write in the entire product — creating an outgoing draft
/// message — and routes renaming, pinning, the bot toggle and the unread badge
/// through callables so a phone can never invent a tick or a 24-hour window.
class ChatActions {
  ChatActions(this._ref);

  final Ref _ref;

  FirebaseFunctions get _functions => _ref.read(functionsProvider);
  FirebaseFirestore get _db => _ref.read(firestoreProvider);

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  /// Send a text message.
  ///
  /// **Synchronous on purpose — there is not a single `await` before the state
  /// mutation.** The bubble must be on screen at the very next vsync; anything
  /// awaited first is a frame the staff member spends looking at an empty
  /// composer.
  String sendText({
    required String waId,
    required String body,
    String? replyToWamid,
  }) {
    final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
    if (uid == null) {
      throw const AppFailure('Dobara sign in karein.', code: 'unauthenticated');
    }

    // v7 is time-ordered, so ids sort the same way messages do — a free
    // tie-break when two messages share a one-second Meta timestamp.
    final messageId = _uuid.v7();
    final now = DateTime.now();

    _ref.read(outboxProvider.notifier).enqueue(
      OutboxEntry(
        id: messageId,
        waId: waId,
        body: body,
        at: now,
        state: OutboxState.inFlight,
        replyToWamid: replyToWamid,
      ),
    );

    // Fire and forget. Firestore's latency compensation puts the document into
    // the live listener's snapshot immediately, online or offline.
    final write = _db
        .messagesOf(waId)
        .doc(messageId)
        .set(draftPayload(uid: uid, body: body, replyToWamid: replyToWamid, at: now));

    unawaited(_dispatch(waId: waId, messageId: messageId, write: write));
    return messageId;
  }

  /// The EXACT document firestore.rules will accept, and nothing more.
  ///
  /// `d.keys().hasOnly([...])` means every key here must be on the allowlist —
  /// a stray field is a silent PERMISSION_DENIED with nothing in the backend
  /// logs to explain it. The four hard requirements are `direction: 'out'`,
  /// `status: 'sending'`, `from` in {staff, owner-cmd} and
  /// `senderStaffId == request.auth.uid`.
  @visibleForTesting
  static Map<String, Object?> draftPayload({
    required String uid,
    required String body,
    required DateTime at,
    String? replyToWamid,
  }) => {
    'direction': 'out',
    'from': 'staff',
    'type': 'text',
    'status': 'sending',
    'statusRank': 0,
    'senderStaffId': uid,
    'text': body,
    'replyToWamid': replyToWamid,
    'previewUrl': _linkPattern.hasMatch(body),
    // Pinning this to 'none' keeps client-written rows out of the reconcile
    // job's stuck-media sweep.
    'mediaStatus': 'none',
    // `timestamp` IS the client timestamp, and sendMessage.js preserves it
    // (`timestamp: doc.timestamp || Timestamp.now()`). This is why the app does
    // not need the usual dual clientTs/serverTs trick — there is exactly one
    // sort key and it never changes between the local echo and the server ack,
    // so a bubble can never reorder under the staff member's thumb.
    'timestamp': Timestamp.fromDate(at),
    'createdAt': FieldValue.serverTimestamp(),
  };

  /// The media equivalent. Same allowlist discipline: every key here is on
  /// `firestore.rules`'s `hasOnly` list, and a stray one is a silent
  /// PERMISSION_DENIED with nothing in the backend logs to explain it.
  ///
  /// `phoneNumberId` is on the draft because `sendMessage.js` needs to know
  /// which of our numbers this goes out from before it can build the Graph API
  /// URL — and it treats the value as a HINT, re-validating it against
  /// `/^\d{5,25}$/` and preferring the chat document's own copy.
  @visibleForTesting
  static Map<String, Object?> mediaDraftPayload({
    required String uid,
    required String type,
    required String mediaPath,
    required String mediaMime,
    required DateTime at,
    required String phoneNumberId,
    String? caption,
    String? fileName,
    int? fileSize,
    int? width,
    int? height,
    String? replyToWamid,
  }) => {
    'direction': 'out',
    'from': 'staff',
    'type': type,
    'status': 'sending',
    'statusRank': 0,
    'senderStaffId': uid,
    'phoneNumberId': phoneNumberId,
    'caption': (caption == null || caption.trim().isEmpty) ? null : caption.trim(),
    'replyToWamid': replyToWamid,
    'mediaPath': mediaPath,
    'mediaMime': mediaMime,
    'fileName': fileName,
    'fileSize': fileSize,
    'mediaWidth': width,
    'mediaHeight': height,
    // Still 'none': the backend flips it to 'stored' once Meta has the bytes.
    // A client-written 'pending' or 'downloading' would be picked up by
    // reconcile.js's stuck-media sweep, which has nothing to do with our own
    // uploads — and firestore.rules pins this to 'none' anyway.
    'mediaStatus': 'none',
    'timestamp': Timestamp.fromDate(at),
    'createdAt': FieldValue.serverTimestamp(),
  };

  // -------------------------------------------------------------------------
  // Sending media
  // -------------------------------------------------------------------------

  /// Send one or more already-compressed attachments.
  ///
  /// **Synchronous on purpose, exactly like [sendText] — not one `await` before
  /// the state mutation.** Every bubble is on screen at the very next vsync,
  /// painting the real photo off this phone's disk with a progress ring on top.
  /// The upload, the draft write and the callable all happen afterwards.
  ///
  /// Returns the message ids it created, oldest first.
  List<String> sendMedia({
    required String waId,
    required String phoneNumberId,
    required List<MediaAttachment> items,
    String? replyToWamid,
  }) {
    final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
    if (uid == null) {
      throw const AppFailure('Dobara sign in karein.', code: 'unauthenticated');
    }
    if (items.isEmpty) return const [];

    final outbox = _ref.read(outboxProvider.notifier);
    final ids = <String>[];
    final now = DateTime.now();

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final messageId = _uuid.v7();
      // One millisecond apart so a batch keeps its picked order in the list —
      // `timestamp` is the only sort key, and List.sort is not stable.
      final at = now.add(Duration(milliseconds: i));
      final prepared = item.upload;

      outbox.enqueue(
        OutboxEntry.media(
          id: messageId,
          waId: waId,
          at: at,
          state: OutboxState.inFlight,
          type: item.messageType,
          localPath: item.previewPath,
          mime: prepared.mime,
          fileName: item.fileName,
          fileSize: prepared.bytes,
          width: prepared.width,
          height: prepared.height,
          caption: item.caption.trim().isEmpty ? null : item.caption.trim(),
          // Only the FIRST item quotes the reply target, the way WhatsApp does
          // it — ten photos each quoting the same message is unreadable.
          replyToWamid: i == 0 ? replyToWamid : null,
        ),
      );
      ids.add(messageId);
    }

    // The bubbles are on screen now. Everything below is network work.
    unawaited(
      _dispatchMediaBatch(
        waId: waId,
        phoneNumberId: phoneNumberId,
        uid: uid,
        ids: ids,
        items: items,
      ),
    );

    return ids;
  }

  Future<void> _dispatchMediaBatch({
    required String waId,
    required String phoneNumberId,
    required String uid,
    required List<String> ids,
    required List<MediaAttachment> items,
  }) async {
    for (var i = 0; i < ids.length; i++) {
      if (i > 0) await Future<void>.delayed(_perRecipientGap);
      await _dispatchMedia(
        waId: waId,
        phoneNumberId: phoneNumberId,
        uid: uid,
        messageId: ids[i],
        item: items[i],
      ).catchError((Object _) {});
    }
  }

  /// Upload → draft → send, for one attachment.
  ///
  /// Every failure lands on the outbox entry as a Hinglish line, so the ghost
  /// row stays put showing the local image with a red strip under it and a
  /// "Dobara bhejein" that actually works. Nothing new is invented here — this
  /// is precisely the mechanism `outbox.dart` already exists to provide.
  Future<void> _dispatchMedia({
    required String waId,
    required String phoneNumberId,
    required String uid,
    required String messageId,
    required MediaAttachment item,
  }) async {
    final outbox = _ref.read(outboxProvider.notifier);
    final prepared = item.upload;

    // ---- 1. Storage ------------------------------------------------------
    final String mediaPath;
    try {
      mediaPath = await mediaUploader.upload(
        media: prepared,
        phoneNumberId: phoneNumberId,
        waId: waId,
        messageId: messageId,
        onProgress: (p) => outbox.setProgress(messageId, p),
      );
      // The path goes onto the ENTRY, not just into this local. It is the only
      // record on this phone of where the bytes landed, and `retry()` needs it
      // to rewrite a draft whose write was rejected.
      outbox.markUploaded(messageId, mediaPath);
    } catch (e) {
      final failure = describeError(e);
      outbox.markFailed(
        messageId,
        failure.code == 'unauthorized' || failure.code == 'permission-denied'
            ? MediaMessages.uploadRejected
            : MediaMessages.uploadOffline,
      );
      return;
    }

    // ---- 2. The draft document ------------------------------------------
    final write = _db.messagesOf(waId).doc(messageId).set(
      mediaDraftPayload(
        uid: uid,
        type: item.messageType,
        mediaPath: mediaPath,
        mediaMime: prepared.mime,
        at: outbox.read(messageId)?.at ?? DateTime.now(),
        phoneNumberId: phoneNumberId,
        caption: item.caption,
        fileName: item.fileName,
        fileSize: prepared.bytes,
        width: prepared.width,
        height: prepared.height,
        replyToWamid: outbox.read(messageId)?.replyToWamid,
      ),
    );

    try {
      // Firestore's set() future never completes while offline — it waits for
      // the server ack, for ever — so it can never be awaited without a
      // deadline on a path a human is watching.
      await write.timeout(_writeDeadline);
      outbox.markDrafted(messageId);
    } on TimeoutException {
      outbox.markFailed(messageId, MediaMessages.uploadOffline);
      return;
    } catch (e) {
      outbox.markFailed(messageId, describeError(e).message, docRolledBack: true);
      return;
    }

    // ---- 3. Hand it to WhatsApp -----------------------------------------
    await _callSend(
      waId: waId,
      messageId: messageId,
      holdLocalPreview: true,
    ).catchError((Object _) {});
  }

  /// Ask the backend to actually put the draft on WhatsApp.
  Future<void> _dispatch({
    required String waId,
    required String messageId,
    required Future<void> write,
    bool holdLocalPreview = false,
  }) async {
    final outbox = _ref.read(outboxProvider.notifier);

    try {
      await write.timeout(_writeDeadline);
    } on TimeoutException {
      // Offline. The write sits in Firestore's queue and flushes on reconnect;
      // the bubble is already on screen. Staff taps retry once there is signal.
      outbox.markFailed(
        messageId,
        'Internet nahi mil raha. Message abhi tak nahi gaya — '
        'network aane par dobara bhejein.',
      );
      return;
    } catch (e) {
      // A rules rejection. Firestore has already rolled the local document
      // back, so without the ghost row the bubble would just disappear.
      final failure = describeError(e);
      outbox.markFailed(messageId, failure.message, docRolledBack: true);
      return;
    }

    // The draft is on the server. Recorded so a later retry knows not to try to
    // write it a second time — `messages` is `allow update: if false`, so a
    // rewrite of a document that already exists is a permanent
    // PERMISSION_DENIED, not a harmless no-op.
    outbox.markDrafted(messageId);

    // `_dispatch` is unawaited, so a rethrown failure here would surface as an
    // unhandled async error. The outbox already carries it onto the bubble.
    await _callSend(
      waId: waId,
      messageId: messageId,
      holdLocalPreview: holdLocalPreview,
    ).catchError((Object _) {});
  }

  Future<void> _callSend({
    required String waId,
    required String messageId,
    bool holdLocalPreview = false,
  }) async {
    final outbox = _ref.read(outboxProvider.notifier);
    try {
      final result = await callGuarded(
        () => _functions
            .httpsCallable(
              'sendMessage',
              options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
            )
            .call<Map<String, dynamic>?>({'waId': waId, 'messageId': messageId}),
      );

      // The backend still holds the send lock on this draft.
      //
      // This is the answer to a retry tapped after an AMBIGUOUS failure — a
      // timeout, or a 5xx after Meta had already accepted the message. The lock
      // is deliberately NOT released on that path (sendMessage.js::recordFailure)
      // because releasing it is how the same saree photo lands on a customer's
      // phone twice. So say what is actually happening instead of leaving the
      // tap looking like it did nothing.
      if (result.data?['inFlight'] == true) {
        outbox.markFailed(
          messageId,
          'Ye message abhi bheja ja raha hai. Thodi der me apne aap update '
          'ho jayega — dobara bhejne ki zaroorat nahi.',
        );
        return;
      }

      // Done. The document's own statusRank drives the tick from here — which
      // is why this flips to `settled` first rather than clearing outright: the
      // entry stops overriding the tick immediately, but keeps feeding
      // `localPath` to the bubble until `mediaUrl` has come down the listener.
      // See OutboxState.settled.
      if (holdLocalPreview) {
        outbox.markSettled(messageId);
        await _awaitMediaUrl(waId, messageId);
      }
      outbox.clear(messageId);
    } on AppFailure catch (f) {
      outbox.markFailed(messageId, f.message);
      // `retry()` awaits this and shows the message. Without the rethrow a
      // second failure was completely silent: staff tapped "Dobara bhejein",
      // nothing moved, nothing was said, and they tapped it again.
      rethrow;
    }
  }

  /// Wait until the row has something remote to paint.
  ///
  /// Best effort and always bounded: the worst case is one extra ghost row for
  /// a few seconds, which clears on the next snapshot anyway. `mediaUrl` OR
  /// `mediaPath` is enough — image_bubble falls back to reading the object out
  /// of Storage by path when the download URL could not be minted.
  Future<void> _awaitMediaUrl(String waId, String messageId) async {
    try {
      await _db
          .messagesOf(waId)
          .doc(messageId)
          .snapshots()
          .firstWhere((s) {
            final data = s.data();
            if (data == null) return false;
            return ((data['mediaUrl'] as String?) ?? '').isNotEmpty ||
                data['mediaStatus'] == 'stored';
          })
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // Offline, slow, or the send never got that far. The bubble falls back to
      // whatever the document says, which is the correct answer either way.
    }
  }

  /// Tap the red "!".
  ///
  /// Safe to tap repeatedly: `sendMessage` claims the draft in a transaction
  /// and refuses one that already carries a wamid, so a customer can never
  /// receive the same message twice.
  Future<void> retry({
    required String waId,
    required Message message,
  }) async {
    final messageId = message.id;
    final outbox = _ref.read(outboxProvider.notifier);
    var entry = outbox.read(messageId);

    if (entry == null) {
      // No entry: this app has restarted since the draft was written, or the
      // draft came from one of the other three phones. `markInFlight` and
      // `markFailed` both return early on a missing entry, so without this the
      // tap produced no clock, and a second failure produced nothing at all.
      //
      // The body and the timestamp come from the RENDERED message so the row
      // keeps its place in the list rather than jumping to the bottom on
      // `DateTime.now()`.
      entry = message.isMedia
          ? OutboxEntry.media(
              id: messageId,
              waId: waId,
              at: message.timestamp,
              state: OutboxState.inFlight,
              type: message.type,
              // Whatever the picker put on disk is long gone after a restart.
              // That is fine: the bytes are already in Storage and the document
              // carries mediaPath, so `sendMessage` has everything it needs.
              localPath: message.localPath,
              mime: message.mediaMime,
              fileName: message.fileName,
              fileSize: message.fileSize,
              width: message.mediaWidth,
              height: message.mediaHeight,
              caption: message.caption,
              uploaded: true,
              drafted: true,
              progress: 1,
              mediaPath: message.mediaPath,
            )
          : OutboxEntry(
              id: messageId,
              waId: waId,
              body: message.body,
              at: message.timestamp,
              state: OutboxState.inFlight,
            );
      outbox.enqueue(entry);
    } else {
      outbox.markInFlight(messageId);
    }

    // ---- MEDIA: how far did the pipeline actually get? ---------------------
    //
    // `_callSend` is only the right thing to do once the bytes are in Storage
    // AND the draft is on the server. Calling it any earlier asks the backend to
    // send a document that is not there, and it answers `not-found` — "That
    // message is gone" — which failure.dart turns into "Network aane par dobara
    // bhejein". That is what made a photo whose upload failed PERMANENTLY
    // UNSENDABLE: the strip told staff to tap retry, every tap took the same
    // dead branch, and nothing ever said "go back to the gallery".
    //
    // `uploaded` and `drafted` were being written by outbox.dart and read by
    // nobody. This is the branch that reads them.
    if (entry.isMedia &&
        (!entry.uploaded || !entry.drafted || entry.docRolledBack)) {
      final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
      final phoneNumberId = _resolvePhoneNumberId(waId);
      if (uid == null) {
        outbox.markFailed(messageId, 'Dobara sign in karein.');
        return;
      }
      if (phoneNumberId == null) {
        outbox.markFailed(messageId, MediaMessages.chatNotReady);
        return;
      }

      // (a) The bytes never got up. Re-run the whole pipeline from the local
      //     file — upload, draft, send.
      if (!entry.uploaded) {
        final local = entry.localPath;
        if (local == null || local.isEmpty || !File(local).existsSync()) {
          // The picker's temp file is gone: the app restarted, or the OS purged
          // its cache. No retry can work from here, so say so plainly instead of
          // looping on an instruction that cannot be followed.
          outbox.markFailed(messageId, MediaMessages.reattachNeeded);
          return;
        }
        final file = File(local);
        final bytes = entry.fileSize ?? await file.length();
        final item = MediaAttachment(
          id: messageId,
          type: switch (entry.type) {
            MsgType.image => 'image',
            MsgType.video => 'video',
            _ => 'document',
          },
          sourcePath: local,
          sourceMime: entry.mime,
          sourceBytes: bytes,
          fileName: entry.fileName,
          caption: entry.caption ?? '',
        );
        // Already compressed once — `localPath` IS the prepared file. Running
        // toChatJpeg over it again would be a second generational quality loss
        // on the fabric texture that is the whole point of the photo.
        item.prepared = PreparedMedia(
          file: file,
          mime: entry.mime ?? 'application/octet-stream',
          bytes: bytes,
          width: entry.width,
          height: entry.height,
        );
        await _dispatchMedia(
          waId: waId,
          phoneNumberId: phoneNumberId,
          uid: uid,
          messageId: messageId,
          item: item,
        );
        return;
      }

      // (b) The bytes ARE up; the draft document is the part in doubt. Same id
      //     throughout, so this is a rewrite and never a second copy — which is
      //     exactly why the id is generated on the client.
      final path = entry.mediaPath;
      if (path == null) {
        outbox.markFailed(messageId, MediaMessages.uploadRejected);
        return;
      }

      Future<void> writeDraft() async {
        final write = _db.messagesOf(waId).doc(messageId).set(
          mediaDraftPayload(
            uid: uid,
            type: entry!.type,
            mediaPath: path,
            mediaMime: entry.mime ?? 'application/octet-stream',
            at: entry.at,
            phoneNumberId: phoneNumberId,
            caption: entry.caption,
            fileName: entry.fileName,
            fileSize: entry.fileSize,
            width: entry.width,
            height: entry.height,
            replyToWamid: entry.replyToWamid,
          ),
        );
        await _dispatch(
          waId: waId,
          messageId: messageId,
          write: write,
          holdLocalPreview: true,
        );
      }

      // The write was DEFINITIVELY refused (a rules rejection), so Firestore
      // rolled the local document back and there is nothing on the server.
      if (entry.docRolledBack) {
        await writeDraft();
        return;
      }

      // ⚠️ Otherwise the write merely TIMED OUT, and "timed out" is not "did
      // not happen": Firestore's set() sits in the offline queue and flushes on
      // reconnect, so the draft may well be there by now. Writing it again would
      // be an UPDATE, and firestore.rules says `allow update: if false` on
      // messages — a straight PERMISSION_DENIED that would loop this branch for
      // ever. Ask the backend first; it is the only thing that knows.
      try {
        await _callSend(
          waId: waId,
          messageId: messageId,
          holdLocalPreview: true,
        );
        outbox.markDrafted(messageId);
      } on AppFailure catch (f) {
        // "That message is gone" — the queued write never landed after all.
        if (f.code == 'not-found') await writeDraft();
      }
      return;
    }

    if (entry.docRolledBack) {
      // The draft never reached Firestore. Write it again under the SAME id.
      final uid = _ref.read(firebaseAuthProvider).currentUser?.uid;
      if (uid == null) {
        outbox.markFailed(messageId, 'Dobara sign in karein.');
        return;
      }

      final write = _db.messagesOf(waId).doc(messageId).set(
        draftPayload(
          uid: uid,
          body: entry.body,
          replyToWamid: entry.replyToWamid,
          at: entry.at,
        ),
      );
      await _dispatch(waId: waId, messageId: messageId, write: write);
      return;
    }

    await _callSend(
      waId: waId,
      messageId: messageId,
      holdLocalPreview: entry.isMedia,
    );
  }

  /// Which of OUR numbers this chat belongs to.
  ///
  /// The chat document wins; the newest tail message is the fallback for a chat
  /// whose document has not arrived yet. `null` means we genuinely do not know,
  /// and in that case no upload is attempted at all — the storage path would be
  /// unbuildable and storage.rules would reject it anyway.
  String? resolvePhoneNumberId(String waId) => _resolvePhoneNumberId(waId);

  String? _resolvePhoneNumberId(String waId) {
    final chat = _ref.read(bestKnownChatProvider(waId));
    final fromChat = chat?.phoneNumberId;
    if (fromChat != null && fromChat.isNotEmpty) return fromChat;

    final tail = _ref.read(liveTailProvider(waId)).value;
    if (tail == null) return null;
    for (final m in tail.messages) {
      final id = m.phoneNumberId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Chat state — all of it backend-owned
  // -------------------------------------------------------------------------

  /// Clears our unread badge and (if the owner has read receipts on) shows the
  /// customer blue ticks. All four phones opening the same chat call this; it
  /// is idempotent by design.
  Future<void> markRead(String waId) => callGuarded(
    () => _functions
        .httpsCallable('markChatRead')
        .call<Map<String, dynamic>?>({'waId': waId}),
  );

  Future<void> _updateChat(String waId, Map<String, Object?> patch) => callGuarded(
    () => _functions
        .httpsCallable('updateChat')
        .call<Map<String, dynamic>?>({'waId': waId, 'patch': patch}),
  );

  Future<void> rename(String waId, String name) =>
      _updateChat(waId, {'name': name});

  Future<void> setPinned(String waId, bool pinned) =>
      _updateChat(waId, {'pinned': pinned});

  Future<void> setBotEnabled(String waId, bool enabled) =>
      _updateChat(waId, {'botEnabled': enabled});

  Future<void> clearAttention(String waId) =>
      _updateChat(waId, {'needsAttention': false});

  /// `null` resumes now; a number is minutes; `true` uses
  /// `settings/app.botPauseMinutes`.
  Future<void> pauseBot(String waId, int? minutes) =>
      _updateChat(waId, {'botPausedUntil': minutes});

  /// Un-pause the bot for this chat right now — the "Bot chalu karein" button
  /// on [BotPausedBanner].
  ///
  /// Note this does NOT clear `chats/{waId}.botEnabled`: the pause is the
  /// automatic 2-hour hush that every staff send sets, while `botEnabled` is
  /// the permanent per-chat off switch in the app bar. Two different things,
  /// two different controls, on purpose.
  Future<void> resumeBot(String waId) =>
      _updateChat(waId, {'botPausedUntil': null});
}

final chatActionsProvider = Provider<ChatActions>(ChatActions.new);
