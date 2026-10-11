import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/firebase/firebase_providers.dart';
import '../domain/tally_models.dart';

/// Collection names, spelled the way the backend spells them.
/// See `functions/lib/db.js` → COLLECTIONS.
abstract final class TallyDb {
  static const bridge = 'tally_bridge';
  static const parties = 'tally_parties';
  static const vouchers = 'tally_vouchers';
  static const sends = 'tally_sends';
  static const counters = 'tally_counters';
  static const runs = 'outstanding_runs';
  static const runParties = 'parties';
}

// ---------------------------------------------------------------------------
// The bridge's health — one document read, and the most valuable one here
// ---------------------------------------------------------------------------

final bridgeStatusProvider = StreamProvider<BridgeStatus>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.bridge)
      .doc('status')
      .snapshots()
      .map(BridgeStatus.fromSnapshot);
}, retry: (_, _) => null);

final bridgeControlProvider = StreamProvider<BridgeControl>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.bridge)
      .doc('control')
      .snapshots()
      .map(BridgeControl.fromSnapshot);
}, retry: (_, _) => null);

/// The banner the CHAT LIST shows — not something buried in Settings.
///
/// A shop PC that has been off since Tuesday is a fact the owner needs in front
/// of him. Returns null when everything is fine, so the widget can be a
/// zero-cost `SizedBox.shrink()` on the happy path.
final bridgeAlertProvider = Provider<String?>((ref) {
  final status = ref.watch(bridgeStatusProvider).value;
  if (status == null) return null;

  if (status.looksDead) {
    final last = status.lastSeen;
    if (last == null) {
      return 'Shop computer se abhi tak koi khabar nahi aayi.';
    }
    final days = DateTime.now().difference(last).inDays;
    final hours = DateTime.now().difference(last).inHours;
    final when =
        '${last.day.toString().padLeft(2, '0')}-${last.month.toString().padLeft(2, '0')}';
    return days >= 1
        ? 'Shop computer $days din se sync nahi hua ($when).'
        : 'Shop computer $hours ghante se sync nahi hua.';
  }
  if (status.isUnhealthy) {
    return status.lastErrorHi ?? 'Shop computer par kuch dikkat hai.';
  }
  return null;
});

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

final recentRunsProvider = StreamProvider<List<OutstandingRun>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.runs)
      .orderBy('builtAt', descending: true)
      .limit(20)
      .snapshots()
      .map((s) => s.docs.map(OutstandingRun.fromSnapshot).toList());
}, retry: (_, _) => null);

/// The one run that wants a tap, if there is one. This is what the hub screen
/// and the settings tile both key off.
final pendingRunProvider = Provider<OutstandingRun?>((ref) {
  final runs = ref.watch(recentRunsProvider).value ?? const <OutstandingRun>[];
  for (final r in runs) {
    if (r.needsApproval) return r;
  }
  return null;
});

final runProvider = StreamProvider.family<OutstandingRun, String>((ref, runId) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.runs)
      .doc(runId)
      .snapshots()
      .map(OutstandingRun.fromSnapshot);
}, retry: (_, _) => null);

/// Ordered biggest debt first, which is also the order the dispatcher sends in.
final runPartiesProvider =
    StreamProvider.family<List<OutstandingParty>, String>((ref, runId) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.runs)
      .doc(runId)
      .collection(TallyDb.runParties)
      .orderBy('duePaise', descending: true)
      .snapshots()
      .map((s) => s.docs.map(OutstandingParty.fromSnapshot).toList());
}, retry: (_, _) => null);

final runPartyProvider =
    StreamProvider.family<OutstandingParty, ({String runId, String partyGuid})>(
        (ref, key) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.runs)
      .doc(key.runId)
      .collection(TallyDb.runParties)
      .doc(key.partyGuid)
      .snapshots()
      .map(OutstandingParty.fromSnapshot);
}, retry: (_, _) => null);

/// What a batch will cost, and how much of it is free.
///
/// Session messages inside the 24-hour window cost nothing; a UTILITY template
/// is roughly ₹0.14 + GST. At 25 parties × 4 runs a month that is about ₹14 —
/// which is not a cost problem. It is shown because the owner should never be
/// surprised by a line on a bill, not because the number is large.
typedef RunCost = ({int templates, int sessions, double inr});

final runCostProvider = Provider.family<RunCost, String>((ref, runId) {
  final parties = ref.watch(runPartiesProvider(runId)).value ?? const [];
  var templates = 0;
  var sessions = 0;
  for (final p in parties) {
    if (!p.isIncludable) continue;
    if (p.willUseTemplate) {
      templates++;
    } else {
      sessions++;
    }
  }
  // Unknown channel (the run has not been sent yet) is counted as a template,
  // because that is the pessimistic direction and the owner should see the
  // larger figure, not the flattering one.
  return (templates: templates, sessions: sessions, inr: templates * 0.14 * 1.18);
});

// ---------------------------------------------------------------------------
// The mobile mapping — the skipped screen is where the real work happens
// ---------------------------------------------------------------------------

final problemPartiesProvider = StreamProvider<List<TallyParty>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.parties)
      .orderBy('ledgerName')
      .limit(500)
      .snapshots()
      .map((s) => s.docs
          .map(TallyParty.fromSnapshot)
          .where((p) => !p.canSend)
          .toList());
}, retry: (_, _) => null);

final tallyPartyProvider = StreamProvider.family<TallyParty, String>((ref, guid) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.parties)
      .doc(guid)
      .snapshots()
      .map(TallyParty.fromSnapshot);
}, retry: (_, _) => null);

/// Grouped by verdict, so the screen reads as "here are the four kinds of
/// problem you have" rather than one long undifferentiated list.
final problemsByVerdictProvider = Provider<Map<String, List<TallyParty>>>((ref) {
  final parties = ref.watch(problemPartiesProvider).value ?? const <TallyParty>[];
  final out = <String, List<TallyParty>>{};
  for (final p in parties) {
    out.putIfAbsent(p.mobileVerdict, () => []).add(p);
  }
  return out;
});

// ---------------------------------------------------------------------------
// The sent log — "kya-kya bheja gaya"
// ---------------------------------------------------------------------------

typedef TallySend = ({
  String sendKey,
  String kind,
  String status,
  String? waId,
  int? amountPaise,
  DateTime? sentAt,
  String? channel,
  String? error,
  bool fellBackToTemplate,
});

final recentSendsProvider = StreamProvider<List<TallySend>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection(TallyDb.sends)
      .orderBy('sentAt', descending: true)
      .limit(200)
      .snapshots()
      .map((s) => s.docs.map((d) {
            final v = d.data();
            return (
              sendKey: d.id,
              kind: v['kind'] as String? ?? 'statement',
              status: v['status'] as String? ?? 'CLAIMED',
              waId: v['waId'] as String?,
              amountPaise: (v['amountPaise'] as num?)?.toInt(),
              sentAt: (v['sentAt'] as Timestamp?)?.toDate(),
              channel: v['channel'] as String?,
              error: v['error'] as String?,
              fellBackToTemplate: v['fellBackToTemplate'] == true,
            );
          }).toList());
}, retry: (_, _) => null);

/// Today's counters, so the caps are visible before they bite.
final tallyCountersTodayProvider = StreamProvider<Map<String, int>>((ref) {
  final db = ref.watch(firestoreProvider);
  // IST day, by fixed-offset arithmetic — the same rule the backend uses.
  final ist = DateTime.now().toUtc().add(const Duration(minutes: 330));
  final day =
      '${ist.year}-${ist.month.toString().padLeft(2, '0')}-${ist.day.toString().padLeft(2, '0')}';
  return db.collection(TallyDb.counters).doc(day).snapshots().map((d) {
    final v = d.data() ?? const {};
    return {
      'statements': (v['statements'] as num?)?.toInt() ?? 0,
      'bills': (v['bills'] as num?)?.toInt() ?? 0,
      'biltys': (v['biltys'] as num?)?.toInt() ?? 0,
      'total': (v['total'] as num?)?.toInt() ?? 0,
    };
  });
}, retry: (_, _) => null);
