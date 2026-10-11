import 'dart:async';
import '../../../core/media/app_image_cache.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/firebase/firebase_providers.dart';
import '../../../core/format/formatters.dart';
import '../../chats/domain/chat.dart';
import '../../chats/providers/chat_list_providers.dart';
import '../data/message_repository.dart';
import '../domain/media_item.dart';
import '../domain/message.dart';
import 'outbox.dart';

final messageRepositoryProvider = Provider<MessageRepository>(
  (ref) => MessageRepository(ref.watch(firestoreProvider)),
);

/// One chat document, live.
final chatDocProvider = StreamProvider.autoDispose.family<Chat?, String>((
  ref,
  waId,
) {
  return ref
      .watch(messageRepositoryProvider)
      .watchChat(waId)
      .map((snap) => snap.exists ? Chat.fromSnapshot(snap) : null);
  // Riverpod 3 retries a failing provider with exponential backoff by DEFAULT.
  // For a Firestore listener that means a permission-denied silently hammers
  // the backend for ever instead of showing the staff member an error.
}, retry: (_, _) => null);

/// The bounded live window — the only listener in the chat.
///
/// Kept alive for [kTailWarm] after the last screen stops watching, so going
/// back to a chat you just left (or one the list pre-warmed on touch-down)
/// opens on already-loaded messages instead of a fresh listener.
const Duration kTailWarm = Duration(minutes: 3);

final liveTailProvider = StreamProvider.autoDispose.family<LiveTail, String>(
  (ref, waId) {
    final link = ref.keepAlive();
    Timer? timer;
    ref.onCancel(() => timer = Timer(kTailWarm, link.close));
    ref.onResume(() => timer?.cancel());
    ref.onDispose(() => timer?.cancel());
    return ref.watch(messageRepositoryProvider).watchTail(waId);
  },
  retry: (_, _) => null,
);

/// The best [Chat] we currently have for this number, and whether we have one
/// at all.
///
/// `chatDocProvider` is a stream: its first value is always at least one
/// platform-channel hop away, and if it errors (`retry` is deliberately
/// disabled) it never arrives. A `null` here means "we genuinely do not know
/// yet" — which is NOT the same as "the 24-hour window is shut", and must never
/// be rendered as if it were.
final bestKnownChatProvider = Provider.autoDispose.family<Chat?, String>((
  ref,
  waId,
) {
  final doc = ref.watch(chatDocProvider(waId));
  final live = doc.value;
  if (live != null) return live;
  return ref.watch(chatSeedProvider(waId));
});

// ---------------------------------------------------------------------------
// History — one-shot pages, never listeners
// ---------------------------------------------------------------------------

@immutable
class MessagePage {
  const MessagePage({
    required this.older,
    required this.cursor,
    required this.exhausted,
    this.evicted = const [],
    this.loading = false,
  });

  const MessagePage.empty()
    : older = const [],
      evicted = const [],
      cursor = null,
      exhausted = false,
      loading = false;

  /// Strictly older than the live tail, newest-first.
  final List<Message> older;

  /// Rows that have dropped OUT of the bounded live tail since the first
  /// history page was anchored — newest-first, and always older than the tail
  /// and newer than [older].
  ///
  /// The first page is anchored on `tail.oldestDoc` *at the moment loadOlder
  /// runs*, and it starts strictly after that document. Anything the tail
  /// evicts afterwards therefore belongs to neither list: with a 30-message
  /// tail, paging once and then receiving five more messages puts a five-message
  /// hole in the MIDDLE of the conversation, with no loading affordance and no
  /// way to get them back short of leaving the chat.
  final List<Message> evicted;

  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool exhausted;
  final bool loading;

  MessagePage copyWith({
    List<Message>? older,
    List<Message>? evicted,
    DocumentSnapshot<Map<String, dynamic>>? cursor,
    bool? exhausted,
    bool? loading,
  }) => MessagePage(
    older: older ?? this.older,
    evicted: evicted ?? this.evicted,
    cursor: cursor ?? this.cursor,
    exhausted: exhausted ?? this.exhausted,
    loading: loading ?? this.loading,
  );

  @override
  bool operator ==(Object other) =>
      other is MessagePage &&
      other.exhausted == exhausted &&
      other.loading == loading &&
      listEquals(other.older, older) &&
      listEquals(other.evicted, evicted);

  @override
  int get hashCode => Object.hash(
    exhausted,
    loading,
    Object.hashAll(older),
    Object.hashAll(evicted),
  );
}

/// Riverpod 3: a family notifier takes its argument through the CONSTRUCTOR
/// and `build()` takes no parameters. (Codegen does the opposite; mixing the
/// two is why so many copied snippets do not compile.)
class MessageHistory extends AsyncNotifier<MessagePage> {
  MessageHistory(this.waId);

  final String waId;
  bool _busy = false;

  @override
  Future<MessagePage> build() async {
    // Watch every tail snapshot go by and keep whatever falls off its oldest
    // edge — see MessagePage.evicted. Only once history has been anchored:
    // before that there is no hole, because loadOlder will anchor on whatever
    // the tail's oldest document happens to be at the time.
    ref.listen(liveTailProvider(waId), (previous, next) {
      final before = previous?.value?.messages;
      final after = next.value?.messages;
      if (before == null || after == null || before.isEmpty || after.isEmpty) {
        return;
      }

      final current = state.value;
      if (current == null) return;
      if (current.cursor == null && !current.loading) return;

      final live = {for (final m in after) m.id};
      final kept = {for (final m in current.evicted) m.id};
      // The oldest row still in the tail. A genuinely evicted message is older
      // than this; a draft Firestore rolled back also "disappears" from the
      // tail but is the NEWEST row, and must not be resurrected here.
      final edge = after.last.timestamp;

      final fallen = [
        for (final m in before)
          if (!live.contains(m.id) &&
              !kept.contains(m.id) &&
              m.timestamp.isBefore(edge))
            m,
      ];
      if (fallen.isEmpty) return;

      // `before` is newest-first and messages always fall off oldest-first, so
      // appending successive batches keeps `evicted` in descending order and
      // the render merge needs no sort.
      state = AsyncData(
        current.copyWith(evicted: [...current.evicted, ...fallen]),
      );
    });

    return const MessagePage.empty();
  }

  /// Append exactly one page of older messages.
  ///
  /// Deliberately a `get()`, not a second `snapshots()`. A cursored query is a
  /// perfectly valid realtime query — that is the trap. One listener per page
  /// means N listeners, N billed re-reads, and windows that fight each other as
  /// new messages push documents across page boundaries.
  Future<void> loadOlder() async {
    if (_busy) return;
    final current = state.value;
    if (current == null || current.exhausted) return;

    final tail = ref.read(liveTailProvider(waId)).value;
    if (tail == null) return;

    // The live tail did not fill its own page, so there is provably nothing
    // older than it.
    if (current.cursor == null && tail.isComplete) {
      state = AsyncData(current.copyWith(exhausted: true));
      return;
    }

    final cursor = current.cursor ?? tail.oldestDoc;
    if (cursor == null) {
      state = AsyncData(current.copyWith(exhausted: true));
      return;
    }

    _busy = true;
    state = AsyncData(current.copyWith(loading: true));
    try {
      final page = await ref
          .read(messageRepositoryProvider)
          .olderThan(waId, cursor);
      if (!ref.mounted) return;

      // Re-read: the tail listener above may have captured evictions while the
      // page was in flight, and `current` is a snapshot from before the await.
      final latest = state.value ?? current;
      state = AsyncData(
        MessagePage(
          older: [
            ...latest.older,
            ...page.docs.map(Message.fromSnapshot),
          ],
          evicted: latest.evicted,
          cursor: page.docs.isEmpty ? cursor : page.docs.last,
          exhausted: page.docs.length < kHistoryPage,
        ),
      );
    } catch (_) {
      if (!ref.mounted) return;
      // A failed page must not poison the screen — the live tail is still
      // perfectly readable. Just stop pretending we are loading.
      state = AsyncData(
        (state.value ?? current).copyWith(loading: false),
      );
    } finally {
      _busy = false;
    }
  }
}

final messageHistoryProvider = AsyncNotifierProvider.autoDispose
    .family<MessageHistory, MessagePage, String>(MessageHistory.new);

// ---------------------------------------------------------------------------
// The store: one flat, render-ready list
// ---------------------------------------------------------------------------

/// Everything one bubble needs, resolved once when the snapshot is built.
///
/// The alternative — working any of this out inside `itemBuilder` — means
/// scanning neighbours on every scroll tick for every visible row, and it is
/// the reason so many Flutter chats run at 40fps.
@immutable
class MessageRow {
  const MessageRow({
    required this.message,
    required this.tick,
    required this.showDateChip,
    required this.isGroupHead,
    required this.isGroupTail,
    this.reactions = const [],
    this.quoted,
  });

  final Message message;
  final Tick tick;

  /// First message of its local calendar day.
  final bool showDateChip;

  /// First of a run by the same sender — the one that gets the tail/nub.
  final bool isGroupHead;

  /// Last of a run — the one that gets the extra gap below.
  final bool isGroupTail;

  /// Emoji the customer reacted with, matched by wamid.
  final List<String> reactions;

  /// The message this one quotes, if it happens to be loaded.
  final Message? quoted;

  String get id => message.id;
  DateTime get timestamp => message.timestamp;
}

@immutable
class ChatSnapshot {
  const ChatSnapshot({
    required this.rows,
    required this.indexById,
    required this.hasMore,
    required this.loading,
    required this.loadingOlder,
    this.error,
  });

  const ChatSnapshot.loading()
    : rows = const [],
      indexById = const {},
      hasMore = false,
      loading = true,
      loadingOlder = false,
      error = null;

  /// Newest first — index 0 is the newest message, matching `reverse: true`.
  final List<MessageRow> rows;
  final Map<String, int> indexById;
  final bool hasMore;
  final bool loading;
  final bool loadingOlder;
  final Object? error;

  bool get isEmpty => rows.isEmpty;

  int? indexOfId(String id) => indexById[id];
}

/// Merges the live tail, the paged history and the in-memory outbox into the
/// single list the screen renders.
final chatSnapshotProvider = Provider.autoDispose.family<ChatSnapshot, String>((
  ref,
  waId,
) {
  final tailAsync = ref.watch(liveTailProvider(waId));
  final historyAsync = ref.watch(messageHistoryProvider(waId));
  final outbox = ref.watch(outboxProvider);

  if (tailAsync.hasError && !tailAsync.hasValue) {
    return ChatSnapshot(
      rows: const [],
      indexById: const {},
      hasMore: false,
      loading: false,
      loadingOlder: false,
      error: tailAsync.error,
    );
  }

  final tail = tailAsync.value;
  if (tail == null) return const ChatSnapshot.loading();

  final history = historyAsync.value ?? const MessagePage.empty();
  final now = DateTime.now();

  // ---- 1. tail first; it is authoritative for any id it contains ----------
  //
  // Descending by construction: the tail is the newest page, `evicted` sits
  // immediately below it, and `older` below that. No sort is needed, and that
  // matters — `List.sort` is not stable, and Meta's inbound timestamps have
  // one-second resolution, so re-sorting can visibly swap two customer messages
  // that share a second.
  final merged = <Message>[];
  final seen = <String>{};
  for (final m in tail.messages) {
    if (seen.add(m.id)) merged.add(m);
  }
  for (final m in history.evicted) {
    if (seen.add(m.id)) merged.add(m);
  }
  for (final m in history.older) {
    if (seen.add(m.id)) merged.add(m);
  }

  // ---- 2. optimistic rows: drafts with no Firestore document YET ----------
  //
  // Two cases, one rule. Either the local echo has not come back over the
  // platform channel (a `set()` is a MethodChannel hop out and an EventChannel
  // hop back — emphatically not the same frame, and slowest exactly when the
  // keyboard is animating right after the tap), or Firestore refused the write
  // and rolled the document back. Rendering only the second case is why the
  // bubble used to appear a few frames late, and why tapping "Dobara bhejein"
  // on a rejected draft made the message disappear: `markInFlight` flipped the
  // state out of `failed` and the row stopped rendering.
  //
  // The moment the real document lands, `seen` holds the id and this is
  // skipped — same id, same ValueKey, same Element, same client `timestamp`
  // (sendMessage.js preserves it), so the handover does not move a pixel.
  for (final entry in outbox.values) {
    if (entry.waId != waId) continue;
    if (seen.contains(entry.id)) continue;
    // Text or media — the entry knows which, and builds the right factory.
    final optimistic = entry.toOptimisticMessage();
    var at = 0;
    while (at < merged.length &&
        merged[at].timestamp.isAfter(optimistic.timestamp)) {
      at++;
    }
    merged.insert(at, optimistic);
    seen.add(entry.id);
  }

  // ---- 3. reactions are their own documents; fold them onto their parent --
  //
  // A reaction has NO `context` — its parent is `reaction.message_id`, which
  // the backend stores in `replyToWamid`. It is never an edit of the message it
  // points at, because that message may be one of ours with a random UUID id.
  final reactionsByWamid = <String, List<String>>{};
  final byWamid = <String, Message>{};
  for (final m in merged) {
    if (m.wamid != null) byWamid[m.wamid!] = m;
  }
  for (final m in merged) {
    if (!m.isReaction) continue;
    final parent = m.replyToWamid;
    final emoji = m.text;
    if (parent == null || m.reactionRemoved || emoji == null || emoji.isEmpty) {
      continue;
    }
    (reactionsByWamid[parent] ??= <String>[]).add(emoji);
  }

  // ---- 4. flags, in one pass ---------------------------------------------
  final visible = merged.where((m) => !m.isReaction).toList(growable: false);
  final rows = List<MessageRow>.generate(visible.length, (i) {
    final cur = visible[i];

    // The list is newest-first, so the message VISUALLY ABOVE this one — the
    // previous one in reading order — is at i + 1.
    final older = i + 1 < visible.length ? visible[i + 1] : null;
    final newer = i - 1 >= 0 ? visible[i - 1] : null;

    final newDay = older == null || !isSameLocalDay(older.timestamp, cur.timestamp);
    final head =
        older == null ||
        newDay ||
        older.direction != cur.direction ||
        cur.timestamp.difference(older.timestamp) > const Duration(minutes: 5);
    final tailOfRun =
        newer == null ||
        newer.direction != cur.direction ||
        !isSameLocalDay(newer.timestamp, cur.timestamp) ||
        newer.timestamp.difference(cur.timestamp) > const Duration(minutes: 5);

    // Merge the in-memory failure onto the row. This is the piece that
    // firestore.rules makes impossible to store on the document.
    //
    // PHASE 4 also merges the local file path and the upload progress. That is
    // what keeps our own photo painted from this phone's disk during the whole
    // window between "the draft document exists" and "mediaUrl has landed" —
    // otherwise the bubble would swap from the real image to a grey box the
    // instant Firestore echoed the draft back, which is the exact opposite of
    // what should happen.
    final entry = outbox[cur.id];
    var withFailure = cur;
    if (entry != null) {
      if (entry.state == OutboxState.failed) {
        withFailure = withFailure.copyWith(
          localFailure: entry.error ?? 'Message bheja nahi ja saka.',
        );
      }
      if (entry.isMedia && entry.localPath != null) {
        withFailure = withFailure.copyWith(
          localPath: entry.localPath,
          uploadProgress: entry.state == OutboxState.inFlight
              ? entry.progress
              : null,
        );
      }
    }

    // While a send is genuinely in flight, keep the clock even if the 90-second
    // staleness rule would otherwise call it dead.
    final tick = entry != null && entry.state == OutboxState.inFlight
        ? Tick.sending
        : withFailure.tickAt(now);

    return MessageRow(
      message: withFailure,
      tick: tick,
      showDateChip: newDay,
      isGroupHead: head,
      isGroupTail: tailOfRun,
      reactions: withFailure.wamid == null
          ? const []
          : (reactionsByWamid[withFailure.wamid!] ?? const []),
      quoted: withFailure.replyToWamid == null
          ? null
          : byWamid[withFailure.replyToWamid!],
    );
  }, growable: false);

  // A spinning 'sending' clock is the only thing on this screen whose
  // appearance changes with the wall clock alone, and `now` is captured once
  // per run. Without this, `Message.tickAt`'s 90-second staleness rule never
  // fires while the chat simply sits open — precisely the case it exists for
  // (the app was killed mid-send, so the in-memory outbox is gone and nothing
  // else in this chat will ever change). One timer for the earliest row that is
  // still pending, never a periodic tick that would rebuild every bubble.
  // `due.isAfter(now)` guarantees a strictly positive delay, so it cannot spin.
  DateTime? nextStaleCheck;
  for (final r in rows) {
    final m = r.message;
    if (!m.isOutgoing || m.localFailure != null) continue;
    if (m.status == 'failed' || (m.statusRank ?? 0) != 0) continue;
    final due = m.timestamp.add(const Duration(seconds: 91));
    if (!due.isAfter(now)) continue;
    if (nextStaleCheck == null || due.isBefore(nextStaleCheck)) {
      nextStaleCheck = due;
    }
  }
  if (nextStaleCheck != null) {
    final timer = Timer(nextStaleCheck.difference(now), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }

  return ChatSnapshot(
    rows: rows,
    indexById: {for (var i = 0; i < rows.length; i++) rows[i].id: i},
    hasMore: !history.exhausted && !tail.isComplete,
    loading: false,
    loadingOlder: history.loading,
    error: null,
  );
});

// ---------------------------------------------------------------------------
// The chat's media, for the full-screen swipe gallery
// ---------------------------------------------------------------------------

/// Every viewable image and video currently LOADED in this chat, oldest →
/// newest, so swiping right moves forward in time.
///
/// Derived from `chatSnapshotProvider`, so it already merges the live tail, the
/// paged history and the outbox and needs no second Firestore query.
///
/// Two honest limitations, written here so nobody is surprised by them:
///  1. it only covers rows that are actually loaded — reaching the first item
///     in the viewer nudges `messageHistoryProvider.loadOlder()` so swiping
///     back through a long day of photos keeps working;
///  2. an item whose bytes have not arrived yet (`mediaStatus` still pending)
///     is left out entirely rather than shown as a black page.
final chatMediaProvider =
    Provider.autoDispose.family<List<MediaItem>, String>((ref, waId) {
      final rows = ref.watch(chatSnapshotProvider(waId)).rows;
      return [
        for (final r in rows.reversed)
          if (r.message.isViewableMedia) MediaItem.from(r.message),
      ];
    });

/// Downloads the previews of every loaded photo in the open chat in the
/// background (newest first, 3 at a time), so scrolling up never waits.
final thumbPrefetchProvider = Provider.autoDispose.family<void, String>((ref, waId) {
  final rows = ref.watch(chatSnapshotProvider(waId)).rows;
  final items = <(String, String)>[];
  for (final r in rows) {
    final m = r.message;
    final t = m.thumbUrl;
    final p = m.mediaPath;
    if (t != null && t.isNotEmpty && p != null && p.isNotEmpty) items.add((t, thumbKey(p)));
    if (items.length >= 120) break;
  }
  prefetchImages(items);
});

// ---------------------------------------------------------------------------
// Reply target — which message the composer is quoting
// ---------------------------------------------------------------------------

class ReplyTarget extends Notifier<Message?> {
  ReplyTarget(this.waId);

  final String waId;

  @override
  Message? build() => null;

  void set(Message message) => state = message;
  void clear() => state = null;
}

final replyTargetProvider = NotifierProvider.autoDispose
    .family<ReplyTarget, Message?, String>(ReplyTarget.new);

// ---------------------------------------------------------------------------
// "I have opened this chat" — the local half of markChatRead
// ---------------------------------------------------------------------------

/// `chats/{waId}` is `allow write: if false`, so the app cannot zero
/// `unreadCount` itself; only the `markChatRead` callable can. That round trip
/// takes a moment, and a badge that lingers after you have opened a chat feels
/// broken. This remembers, on THIS phone, how fresh the chat was when it was
/// opened, and the tile hides the badge until something newer arrives.
class LocallyRead extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() => const {};

  void mark(String waId, DateTime upTo) {
    final existing = state[waId];
    if (existing != null && !upTo.isAfter(existing)) return;
    state = {...state, waId: upTo};
  }

  bool isRead(String waId, DateTime? lastMessageAt) {
    final marked = state[waId];
    if (marked == null) return false;
    if (lastMessageAt == null) return true;
    return !lastMessageAt.isAfter(marked);
  }
}

final locallyReadProvider =
    NotifierProvider<LocallyRead, Map<String, DateTime>>(LocallyRead.new);
