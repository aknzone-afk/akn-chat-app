import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/firebase/firebase_providers.dart';
import '../domain/bot_log.dart';

/// Collection names for the three Phase 5 collections, spelled the way
/// functions/lib/db.js spells them.
abstract final class BotDb {
  static const botLogs = 'bot_logs';
  static const products = 'products';
  static const billRequests = 'bill_requests';
}

/// One turn, by the id of the INBOUND message that caused it.
///
/// A bot message carries that id as `botTurnId`, so the "Ye reply kyun?" sheet
/// is a single `doc().get()` — no query, no index, no cost worth counting.
/// `.future`, not a stream: the row is written once and patched once, and a
/// bottom sheet does not need to watch it.
final botLogProvider = FutureProvider.family<BotLog?, String>((ref, turnId) async {
  final db = ref.watch(firestoreProvider);
  final snap = await db.collection(BotDb.botLogs).doc(turnId).get();
  if (!snap.exists) return null;
  return BotLog.fromSnapshot(snap);
});

/// "Bot ne aaj kya kiya" — the newest 50 turns across every chat, INCLUDING
/// the ones where it stayed quiet. A missing row and a crash look identical,
/// which is exactly why the silent turns are logged too.
///
/// Needs no composite index: a single `orderBy` on one field is served by the
/// automatic single-field index.
final recentBotLogsProvider = StreamProvider<List<BotLog>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(BotDb.botLogs)
      .orderBy('ts', descending: true)
      .limit(50)
      .snapshots()
      .map((q) => q.docs.map(BotLog.fromSnapshot).toList(growable: false));
}, retry: (_, _) => null);

/// Every turn in the last 24 hours — the window the "Pichhle 24 ghante" card
/// actually claims to describe.
///
/// ⚠️ This must NOT be a "newest 50" sample. `bot_logs` gets one row per inbound
/// message the bot looked at (the lock row is written before any gate), so at
/// ~100 chats a day that is 300-500 rows and the newest 50 covers about two
/// hours. Summing the ₹ figure off that sample under-read the owner's own spend
/// by roughly ten times — the exact wrong input to the one decision this screen
/// exists to inform: attach billing, or stay on the free tier.
///
/// Bounded at 500 so a runaway day cannot blow the phone's memory; the card says
/// "500+" when it binds. A range filter plus an orderBy on the SAME single field
/// needs no composite index.
final botLogsLast24hProvider = StreamProvider<List<BotLog>>((ref) {
  final db = ref.watch(firestoreProvider);
  final since = Timestamp.fromDate(
    DateTime.now().subtract(const Duration(hours: 24)),
  );
  return db
      .collection(BotDb.botLogs)
      .where('ts', isGreaterThan: since)
      .orderBy('ts', descending: true)
      .limit(500)
      .snapshots()
      .map((q) => q.docs.map(BotLog.fromSnapshot).toList(growable: false));
}, retry: (_, _) => null);

/// What the bot has cost today, in rupees, straight off the logged token
/// counts. The owner is paying for this; he should be able to see it without
/// opening a Google Cloud billing page.
final botCostTodayProvider =
    Provider<({double inr, int turns, int aiTurns, bool capped})>((ref) {
      final logs = ref.watch(botLogsLast24hProvider).value ?? const <BotLog>[];
      var inr = 0.0;
      var turns = 0;
      var aiTurns = 0;
      for (final log in logs) {
        turns++;
        if (log.usedAi) aiTurns++;
        inr += log.totalCostInr;
      }
      return (inr: inr, turns: turns, aiTurns: aiTurns, capped: logs.length >= 500);
    });

/// Bill jobs waiting for Phase 6's Tally bridge. Shown in the app so staff can
/// see "bill nikal raha hai" and chase one that is stuck, rather than the
/// customer being the one who notices.
final pendingBillRequestsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(BotDb.billRequests)
      .where('status', isEqualTo: 'pending')
      .orderBy('createdAt')
      .limit(30)
      .snapshots()
      .map(
        (q) => q.docs
            .map((d) => {'id': d.id, ...d.data()})
            .toList(growable: false),
      );
}, retry: (_, _) => null);

/// One catalogue row, for the audit sheet. `products` is `allow read: if
/// isStaff()`, so the app can show exactly what the bot quoted from.
final productProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  designNo,
) async {
  final db = ref.watch(firestoreProvider);
  final snap = await db.collection(BotDb.products).doc(designNo).get();
  return snap.exists ? snap.data() : null;
});
