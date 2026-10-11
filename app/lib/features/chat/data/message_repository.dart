import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/firebase/firebase_providers.dart';
import '../domain/message.dart';

/// How many messages the LIVE listener watches. Everything older is fetched
/// once with `get()` and never listened to again — history is immutable, and
/// paying to watch it is how a chat app quietly triples its Firestore bill.
const int kLiveTail = 30;

/// One page of older messages.
const int kHistoryPage = 30;

/// The live tail, plus the raw document at its oldest edge.
///
/// Keeping the `DocumentSnapshot` here is what lets pagination use
/// `startAfterDocument` without a second round trip to find the anchor — and
/// `startAfterDocument` (rather than `startAfter([timestamp])`) is what makes
/// the page boundary exact when two messages share a timestamp, which they do
/// constantly: Meta's timestamps have one-second resolution.
@immutable
class LiveTail {
  const LiveTail({required this.messages, required this.oldestDoc});

  const LiveTail.empty() : messages = const [], oldestDoc = null;

  final List<Message> messages;
  final DocumentSnapshot<Map<String, dynamic>>? oldestDoc;

  /// Fewer than a full page means there is provably nothing older.
  bool get isComplete => messages.length < kLiveTail;

  @override
  bool operator ==(Object other) =>
      other is LiveTail &&
      other.oldestDoc?.id == oldestDoc?.id &&
      listEquals(other.messages, messages);

  @override
  int get hashCode => Object.hash(oldestDoc?.id, Object.hashAll(messages));
}

class MessageRepository {
  MessageRepository(this._db);

  final FirebaseFirestore _db;

  Query<Map<String, dynamic>> _ordered(String waId) =>
      _db.messagesOf(waId).orderBy('timestamp', descending: true);

  /// The bounded live window.
  ///
  /// `includeMetadataChanges: true` is required, not optional: without it the
  /// stream fires only when document *data* changes, so the moment a local
  /// write is acknowledged by the server — where the only thing that changed is
  /// `hasPendingWrites: true → false` — produces no event at all.
  Stream<LiveTail> watchTail(String waId) => _ordered(waId)
      .limit(kLiveTail)
      .snapshots(includeMetadataChanges: true)
      .map(
        (qs) => LiveTail(
          messages: qs.docs.map(Message.fromSnapshot).toList(growable: false),
          oldestDoc: qs.docs.isEmpty ? null : qs.docs.last,
        ),
      );

  /// One immutable page of history. A `get()`, never a listener.
  Future<QuerySnapshot<Map<String, dynamic>>> olderThan(
    String waId,
    DocumentSnapshot<Map<String, dynamic>> cursor,
  ) => _ordered(waId).startAfterDocument(cursor).limit(kHistoryPage).get();

  DocumentReference<Map<String, dynamic>> draftRef(String waId, String messageId) =>
      _db.messagesOf(waId).doc(messageId);

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchChat(String waId) =>
      _db.chatDoc(waId).snapshots();
}
