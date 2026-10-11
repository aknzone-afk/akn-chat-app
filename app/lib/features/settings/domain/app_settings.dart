import 'package:cloud_firestore/cloud_firestore.dart';

/// `settings/app`, mirroring functions/lib/settings.js DEFAULT_SETTINGS.
///
/// READ directly from Firestore (`settings: allow read: if isStaff()`), WRITTEN
/// only through the `updateSettings` callable — see
/// features/settings/data/settings_actions.dart. The document itself stays
/// `allow write: if false`, because the whitelist, the length bounds and the
/// owner check on `geminiPersona` are all things a rules expression cannot say.
class AppSettings {
  const AppSettings({
    this.botGlobalEnabled = false,
    this.botPauseMinutes = 120,
    this.sendReadReceipts = true,
    this.ownerNumbers = const [],
    this.quickReplies = const [],
    this.geminiPersona = '',
    this.staffNames = const {},
    this.numberLabels = const {},
    this.botReplyMaxPer10Min = 3,
    this.botReplyMaxPer24h = 20,
    this.botMinConfidence = 0.75,
    this.botDisclosure = true,
    this.productPriceMaxAgeDays = 60,
    this.defaultMoq = 10,
    this.tallyGlobalEnabled = false,
    this.tallyRequireExistingChat = true,
    this.tallyMinDaysBetweenStatements = 7,
    this.tallyHolidays = const [],
    this.tallyTemplateLang = 'en',
    this.outstandingAutoApprove = false,
    this.schemaVersion = 0,
    this.exists = false,
  });

  final bool botGlobalEnabled;
  final int botPauseMinutes;
  final bool sendReadReceipts;
  final List<String> ownerNumbers;
  final List<String> quickReplies;

  /// `settings/app.numbers` → `{phoneNumberId: label}`. Empty with one number.
  final Map<String, String> numberLabels;

  /// The bot's persona — owner-editable, and the only free text the model ever
  /// sees from us. It CANNOT make the bot state a price: prices never route
  /// through the model at all, and the egress filter refuses any composed line
  /// containing a number. Those two facts are what make it safe to edit.
  final String geminiPersona;

  /// uid → display name. `staff` is `allow list: if false`, so this map is the
  /// only way a bubble can say who replied.
  final Map<String, String> staffNames;

  // ---- Phase 5 rails ------------------------------------------------------
  final int botReplyMaxPer10Min;
  final int botReplyMaxPer24h;
  final double botMinConfidence;
  final bool botDisclosure;

  /// Refuse to quote a price whose CSV import is older than this many days.
  /// 0 means never refuse — not recommended: a stale catalogue is the one price
  /// risk the architecture cannot defend against on its own.
  final int productPriceMaxAgeDays;

  final int defaultMoq;

  // ---- Phase 6 rails ------------------------------------------------------

  /// ⚠️ SHIPS FALSE, exactly like [botGlobalEnabled]. Nothing the Tally bridge
  /// produces reaches a customer until somebody deliberately arms it. Work
  /// through the first-run rehearsal in `functions/README.md`, in order,
  /// before flipping this.
  final bool tallyGlobalEnabled;

  /// Only message a party who already has a chat with us. "Already messaged
  /// us" is objective, auditable evidence of opt-in; "a number in a ledger" is
  /// not — and a stale 2019 number now belongs to a stranger who would receive
  /// a demand for money with another firm's name on it.
  final bool tallyRequireExistingChat;

  /// Enforced server-side on the SEND, not only at build time.
  final int tallyMinDaysBetweenStatements;

  /// IST "YYYY-MM-DD" days on which nothing is ever sent. A dunning message on
  /// a festival day is the wrong message.
  final List<String> tallyHolidays;

  /// ⚠️ "en" and "en_US" are DIFFERENT TEMPLATES to Meta.
  final String tallyTemplateLang;

  /// Cannot be turned on until three consecutive runs have been approved with
  /// zero exclusions, zero warnings and zero disputes.
  final bool outstandingAutoApprove;

  final int schemaVersion;

  /// False when `settings/app` has not been seeded.
  final bool exists;

  /// Phase 5 keys are missing until seedOnce has been re-run.
  bool get needsReseed => exists && schemaVersion < 3;

  /// Phase 6 keys likewise.
  bool get needsTallyReseed => exists && schemaVersion < 4;

  factory AppSettings.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    return AppSettings(
      botGlobalEnabled: d['botGlobalEnabled'] == true,
      botPauseMinutes: _int(d['botPauseMinutes'], 120),
      sendReadReceipts: d['sendReadReceipts'] != false,
      ownerNumbers: _strings(d['ownerNumbers']),
      quickReplies: _strings(d['quickReplies']),
      geminiPersona: d['geminiPersona'] as String? ?? '',
      staffNames: d['staffNames'] is Map
          ? (d['staffNames'] as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            )
          : const {},
      numberLabels: _numberLabels(d['numbers']),
      botReplyMaxPer10Min: _int(d['botReplyMaxPer10Min'], 3),
      botReplyMaxPer24h: _int(d['botReplyMaxPer24h'], 20),
      botMinConfidence: d['botMinConfidence'] is num
          ? (d['botMinConfidence'] as num).toDouble()
          : 0.75,
      botDisclosure: d['botDisclosure'] != false,
      productPriceMaxAgeDays: _int(d['productPriceMaxAgeDays'], 60),
      defaultMoq: _int(d['defaultMoq'], 10),
      tallyGlobalEnabled: d['tallyGlobalEnabled'] == true,
      tallyRequireExistingChat: d['tallyRequireExistingChat'] != false,
      tallyMinDaysBetweenStatements: _int(d['tallyMinDaysBetweenStatements'], 7),
      tallyHolidays: _strings(d['tallyHolidays']),
      tallyTemplateLang: d['tallyTemplateLang'] as String? ?? 'en',
      outstandingAutoApprove: d['outstandingAutoApprove'] == true,
      schemaVersion: _int(d['schemaVersion'], 0),
      exists: snap.exists,
    );
  }

  static Map<String, String> _numberLabels(Object? v) {
    if (v is! Map) return const {};
    final out = <String, String>{};
    v.forEach((k, cfg) {
      final label = cfg is Map ? cfg['label'] : null;
      if (label is String && label.trim().isNotEmpty) out[k.toString()] = label.trim();
    });
    return out;
  }

  static List<String> _strings(Object? v) => v is List
      ? v.whereType<Object>().map((e) => e.toString()).toList(growable: false)
      : const [];

  static int _int(Object? v, int fallback) =>
      v is num ? v.toInt() : fallback;
}
