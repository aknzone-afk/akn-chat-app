import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/contacts/phone_contacts.dart';
import '../../../core/firebase/firebase_providers.dart';
import '../../chat/providers/chat_providers.dart';
import '../domain/chat.dart';

/// How many chats the home screen keeps live. Four staff phones on a busy day
/// never scroll past this, and it bounds the listener cost.
const int kChatListLimit = 10000; // owner 11-Oct-2026: no cap (~600 chats today)

/// The chat list, live.
///
/// Ordered by `lastMessageAt` ALONE, even though a `(pinned, lastMessageAt)`
/// composite index exists. Firestore drops any document that is missing a field
/// being ordered on, and `pinned` is only written in ingest.js's `isNewChat`
/// branch — so ordering on it would silently hide every chat created before
/// that branch existed. Pinned chats are partitioned client-side instead.
/// 11-Oct-2026: 240 reminders in one morning pushed every older Inquiries
/// chat out of the newest-250 window. Now each number tab asks Firestore for
/// ITS OWN newest chats, and scrolling to the end loads 200 more.
class ChatListLimit extends Notifier<int> {
  @override
  int build() => kChatListLimit;

  void more() => state = state + 200;
}

final chatListLimitProvider = NotifierProvider<ChatListLimit, int>(ChatListLimit.new);

final chatsStreamProvider = StreamProvider<List<Chat>>((ref) {
  final db = ref.watch(firestoreProvider);
  final number = ref.watch(numberFilterProvider);
  final limit = ref.watch(chatListLimitProvider);
  Query<Map<String, dynamic>> q = db.collection(Db.chats);
  if (number != null) q = q.where('phoneNumberId', isEqualTo: number);
  return q
      .orderBy('lastMessageAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((qs) => qs.docs.map(Chat.fromSnapshot).toList(growable: false));
}, retry: (_, _) => null);

/// The chat exactly as the home screen already knows it.
///
/// The chat list stays mounted underneath a pushed chat screen, so this data is
/// already in memory. The chat screen uses it as a seed while
/// `chatDocProvider`'s first snapshot is still crossing the platform channel —
/// otherwise every chat open renders a `Chat` with `windowExpiresAt == null`,
/// which reads as "window closed" and flashes a locked composer plus a paid
/// template warning on a conversation that is very probably free to reply to.
final chatSeedProvider = Provider.autoDispose.family<Chat?, String>((ref, waId) {
  final chats = ref.watch(chatsStreamProvider).value;
  if (chats == null) return null;
  for (final c in chats) {
    if (c.waId == waId) return c;
  }
  return null;
});

class ChatSearch extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

final chatSearchProvider = NotifierProvider<ChatSearch, String>(ChatSearch.new);

/// customer waId → Tally ledger (party) name, from `tally_parties`. Empty until
/// the Tally bridge has synced parties; a chat with no match keeps its own name.
final partyNamesProvider = StreamProvider<Map<String, String>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db.collection('tally_parties').snapshots().map((qs) {
    final out = <String, String>{};
    for (final d in qs.docs) {
      final data = d.data();
      final waId = data['waId'];
      final name = data['ledgerName'] ?? data['partyName'];
      if (waId is String && waId.isNotEmpty && name is String && name.trim().isNotEmpty) {
        out[waId] = name.trim();
      }
    }
    return out;
  });
}, retry: (_, _) => null);

/// What the chat list and header call a chat: a name staff typed wins, then the
/// Tally party name, then the WhatsApp profile name / number.
/// Owner, 11-Oct-2026: like WhatsApp — the name saved in THIS phone's
/// contacts first, then the name saved in the WhatsApp Business app.
String chatTitle(Chat chat, Map<String, String> partyNames,
    [Map<String, String> phoneBook = const {}]) {
  final saved = phoneBook[last10(chat.customerWaId)]?.trim();
  if (saved != null && saved.isNotEmpty) return saved;
  final biz = chat.phoneSavedName?.trim();
  if (biz != null && biz.isNotEmpty) return biz;
  if (chat.hasCustomName) return chat.displayName;
  return partyNames[chat.customerWaId] ?? chat.displayName;
}

const _designTypes = {'image', 'video', 'document'};

/// "Customer ne designs bheje": the customer's last message is a photo, video or
/// PDF and nobody has opened it yet (on this phone or any other).
bool hasUnseenDesigns(Chat c, Map<String, DateTime> locallyRead) {
  if (c.unreadCount <= 0 || !_designTypes.contains(c.lastMessageType)) return false;
  final last = c.lastMessageAt;
  final customer = c.lastCustomerMsgAt;
  if (last == null || customer == null || last.isAfter(customer)) return false;
  final marked = locallyRead[c.waId];
  return marked == null || last.isAfter(marked);
}

final unseenDesignChatsProvider = Provider<List<Chat>>((ref) {
  final chats = ref.watch(chatsStreamProvider).value ?? const <Chat>[];
  final read = ref.watch(locallyReadProvider);
  return chats.where((c) => hasUnseenDesigns(c, read)).toList(growable: false);
});

/// True while the list shows only the "designs bheje" chats.
class DesignsOnly extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final designsOnlyProvider = NotifierProvider<DesignsOnly, bool>(DesignsOnly.new);

/// Which business number the list shows — a phoneNumberId, or null for all.
class NumberFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? phoneNumberId) => state = phoneNumberId;
}

final numberFilterProvider = NotifierProvider<NumberFilter, String?>(NumberFilter.new);

/// WhatsApp's "Unread" chip (owner, 6-Oct-2026): only chats where the customer
/// wrote last and nobody has looked yet.
class UnreadOnly extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final unreadOnlyProvider = NotifierProvider<UnreadOnly, bool>(UnreadOnly.new);

/// Filter by name or number, then float the pinned chats to the top.
final visibleChatsProvider = Provider<List<Chat>>((ref) {
  final chats = ref.watch(chatsStreamProvider).value ?? const <Chat>[];
  final query = ref.watch(chatSearchProvider).trim().toLowerCase();
  final number = ref.watch(numberFilterProvider);
  final partyNames = ref.watch(partyNamesProvider).value ?? const <String, String>{};
  final phoneBook = ref.watch(phoneContactNamesProvider).value ?? const <String, String>{};
  final designsOnly = ref.watch(designsOnlyProvider);
  final unreadOnly = ref.watch(unreadOnlyProvider);
  final read = designsOnly ? ref.watch(locallyReadProvider) : const <String, DateTime>{};
  final byNumber = chats.where((c) {
    if (number != null && c.phoneNumberId != number) return false;
    if (designsOnly && !hasUnseenDesigns(c, read)) return false;
    if (unreadOnly && c.unreadCount <= 0) return false;
    return true;
  }).toList(growable: false);

  final filtered = query.isEmpty
      ? byNumber
      : byNumber.where((c) {
          final digits = query.replaceAll(RegExp(r'\D'), '');
          return c.displayName.toLowerCase().contains(query) ||
              (partyNames[c.customerWaId] ?? '').toLowerCase().contains(query) ||
              (digits.isNotEmpty && c.customerWaId.contains(digits)) ||
              (c.profileName ?? '').toLowerCase().contains(query) ||
              (c.phoneSavedName ?? '').toLowerCase().contains(query) ||
              (phoneBook[last10(c.customerWaId)] ?? '').toLowerCase().contains(query);
        }).toList(growable: false);

  final pinned = <Chat>[];
  final rest = <Chat>[];
  for (final c in filtered) {
    (c.pinned ? pinned : rest).add(c);
  }
  return [...pinned, ...rest];
});

/// The badge on the app title — how many chats are waiting.
final unreadChatCountProvider = Provider<int>((ref) {
  final chats = ref.watch(chatsStreamProvider).value ?? const <Chat>[];
  return chats.where((c) => c.unreadCount > 0).length;
});

/// Every unread MESSAGE in every chat — the number on the iOS app icon.
///
/// Deliberately not the chat count above: the server sends the message total
/// (`AggregateField.sum('unreadCount')` in notifyInbound.js), and a badge that
/// counted chats on the way down and messages on the way up would jump about.
/// See features/push/app_badge.dart.
final totalUnreadMessagesProvider = Provider<int>((ref) {
  final chats = ref.watch(chatsStreamProvider).value ?? const <Chat>[];
  var total = 0;
  for (final c in chats) {
    if (c.unreadCount > 0) total += c.unreadCount;
  }
  return total;
});
