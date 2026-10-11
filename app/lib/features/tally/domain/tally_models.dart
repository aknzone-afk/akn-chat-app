import 'package:cloud_firestore/cloud_firestore.dart';

/// Phase 6 read models. Every one of these is **read-only** — `firestore.rules`
/// keeps the whole Tally block `allow write: if false`, and every change goes
/// through the `tallyAdmin` callable.
///
/// That is not defensiveness. A phone that could write
/// `tally_parties.mobileOverride` could redirect another firm's outstanding
/// statement to a number of its choosing.

// ---------------------------------------------------------------------------
// tally_bridge/status — the dead man's switch the chat list reads
// ---------------------------------------------------------------------------

class BridgeStatus {
  const BridgeStatus({
    this.health = 'unknown',
    this.lastSeen,
    this.lastOkCycleAt,
    this.lastErrorAssertion,
    this.lastErrorHi,
    this.bridgeVersion,
    this.companyName,
    this.partyCount,
    this.lastVoucherAlterId,
    this.lastOutstandingRunId,
  });

  final String health;
  final DateTime? lastSeen;
  final DateTime? lastOkCycleAt;
  final String? lastErrorAssertion;
  final String? lastErrorHi;
  final String? bridgeVersion;
  final String? companyName;
  final int? partyCount;
  final int? lastVoucherAlterId;
  final String? lastOutstandingRunId;

  factory BridgeStatus.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final err = d['lastError'] as Map<String, dynamic>?;
    return BridgeStatus(
      health: d['health'] as String? ?? 'unknown',
      lastSeen: (d['lastSeen'] as Timestamp?)?.toDate(),
      lastOkCycleAt: (d['lastOkCycleAt'] as Timestamp?)?.toDate(),
      lastErrorAssertion: err?['assertion'] as String?,
      lastErrorHi: err?['messageHi'] as String? ?? err?['message'] as String?,
      bridgeVersion: d['bridgeVersion'] as String?,
      companyName: d['companyName'] as String?,
      partyCount: (d['partyCount'] as num?)?.toInt(),
      lastVoucherAlterId: (d['lastVoucherAlterId'] as num?)?.toInt(),
      lastOutstandingRunId: d['lastOutstandingRunId'] as String?,
    );
  }

  /// How long since the shop PC last checked in.
  Duration? get silence =>
      lastSeen == null ? null : DateTime.now().difference(lastSeen!);

  /// ⚠️ **The single highest-value alert in this phase.**
  ///
  /// Logs on a shop PC are write-only media — nobody will ever open them. This
  /// puts the failure in front of the person who cares, in the place he already
  /// looks, in his own language. 90 minutes, because a shop PC that is merely
  /// slow should not cry wolf, and one that has been off since Tuesday should.
  bool get looksDead {
    final s = silence;
    return s == null || s > const Duration(minutes: 90);
  }

  bool get isUnhealthy => health == 'unhealthy' || lastErrorAssertion != null;
}

// ---------------------------------------------------------------------------
// tally_bridge/control — the switches
// ---------------------------------------------------------------------------

class BridgeControl {
  const BridgeControl({
    this.killSwitch = false,
    this.dryRun = false,
    this.rehearsalTo,
    this.billMode = 'rehearsal',
    this.biltyMode = 'rehearsal',
    this.updatedByName,
    this.updatedAt,
  });

  final bool killSwitch;
  final bool dryRun;
  final String? rehearsalTo;
  final String billMode;
  final String biltyMode;
  final String? updatedByName;
  final DateTime? updatedAt;

  factory BridgeControl.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return BridgeControl(
      killSwitch: d['killSwitch'] == true,
      dryRun: d['dryRun'] == true,
      rehearsalTo: d['rehearsalTo'] as String?,
      billMode: d['billMode'] as String? ?? 'rehearsal',
      biltyMode: d['biltyMode'] as String? ?? 'rehearsal',
      updatedByName: d['updatedByName'] as String?,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

// ---------------------------------------------------------------------------
// outstanding_runs/{runId}
// ---------------------------------------------------------------------------

class RunWarning {
  const RunWarning({required this.code, required this.messageHi, this.severity = 'warn'});
  final String code;
  final String messageHi;
  final String severity;

  factory RunWarning.fromMap(Map<String, dynamic> m) => RunWarning(
    code: m['code'] as String? ?? 'warning',
    messageHi: m['messageHi'] as String? ?? m['message'] as String? ?? '',
    severity: m['severity'] as String? ?? 'warn',
  );
}

class SkippedParty {
  const SkippedParty({
    required this.partyName,
    required this.skipReason,
    required this.skipReasonHi,
    this.partyGuid,
    this.waId,
    this.mobileVerdict,
    this.mobileRaw,
    this.mobileCandidates = const [],
    this.duplicateWith = const [],
    this.duePaise,
    this.billsSumPaise,
    this.ledgerClosingPaise,
    this.reconcileDiffPaise,
  });

  final String partyName;
  final String skipReason;
  final String skipReasonHi;
  final String? partyGuid;
  final String? waId;
  final String? mobileVerdict;
  final String? mobileRaw;
  final List<String> mobileCandidates;
  final List<String> duplicateWith;
  final int? duePaise;
  final int? billsSumPaise;
  final int? ledgerClosingPaise;
  final int? reconcileDiffPaise;

  factory SkippedParty.fromMap(Map<String, dynamic> m) => SkippedParty(
    partyName: m['partyName'] as String? ?? '—',
    skipReason: m['skipReason'] as String? ?? 'unknown',
    skipReasonHi: m['skipReasonHi'] as String? ?? '',
    partyGuid: m['partyGuid'] as String?,
    waId: m['waId'] as String?,
    mobileVerdict: m['mobileVerdict'] as String?,
    mobileRaw: m['mobileRaw'] as String?,
    mobileCandidates: (m['mobileCandidates'] as List?)?.cast<String>() ?? const [],
    duplicateWith: (m['duplicateWith'] as List?)?.cast<String>() ?? const [],
    duePaise: (m['duePaise'] as num?)?.toInt(),
    billsSumPaise: (m['billsSumPaise'] as num?)?.toInt(),
    ledgerClosingPaise: (m['ledgerClosingPaise'] as num?)?.toInt(),
    reconcileDiffPaise: (m['reconcileDiffPaise'] as num?)?.toInt(),
  );

  /// True when the reason is that the bill-wise total did not equal the
  /// ledger's own closing balance — which is a fact about the BOOKS, and worth
  /// showing the owner even though it is not his fault.
  bool get isMoneyProblem => skipReason == 'on_account_or_unallocated' || skipReason == 'parse_failed';
}

class OutstandingRun {
  const OutstandingRun({
    required this.runId,
    required this.status,
    this.builtAt,
    this.asOnIso,
    this.thresholdDays,
    this.ageingBasis,
    this.partyCount = 0,
    this.includedCount = 0,
    this.sentCount = 0,
    this.failedCount = 0,
    this.totalPaise = 0,
    this.oldestDebitAgeDays,
    this.warnings = const [],
    this.skipped = const [],
    this.acknowledgedWarnings = false,
    this.approvedByName,
    this.approvedAt,
    this.abortReasonHi,
    this.staleReasonHi,
    this.templateProblemHi,
  });

  final String runId;

  /// `building` · `awaiting_approval` · `approved` · `sending` · `done`
  /// `cancelled` · `expired` · `stale` · `aborted`
  final String status;
  final DateTime? builtAt;
  final String? asOnIso;
  final int? thresholdDays;
  final String? ageingBasis;
  final int partyCount;
  final int includedCount;
  final int sentCount;
  final int failedCount;
  final int totalPaise;
  final int? oldestDebitAgeDays;
  final List<RunWarning> warnings;
  final List<SkippedParty> skipped;
  final bool acknowledgedWarnings;
  final String? approvedByName;
  final DateTime? approvedAt;
  final String? abortReasonHi;
  final String? staleReasonHi;
  final String? templateProblemHi;

  factory OutstandingRun.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return OutstandingRun(
      runId: doc.id,
      status: d['status'] as String? ?? 'unknown',
      builtAt: (d['builtAt'] as Timestamp?)?.toDate(),
      asOnIso: d['asOnIso'] as String?,
      thresholdDays: (d['thresholdDays'] as num?)?.toInt(),
      ageingBasis: d['ageingBasis'] as String?,
      partyCount: (d['partyCount'] as num?)?.toInt() ?? 0,
      includedCount: (d['includedCount'] as num?)?.toInt() ?? 0,
      sentCount: (d['sentCount'] as num?)?.toInt() ?? 0,
      failedCount: (d['failedCount'] as num?)?.toInt() ?? 0,
      totalPaise: (d['totalPaise'] as num?)?.toInt() ?? 0,
      oldestDebitAgeDays: (d['oldestDebitAgeDays'] as num?)?.toInt(),
      warnings: ((d['warnings'] as List?) ?? const [])
          .map((w) => RunWarning.fromMap(Map<String, dynamic>.from(w as Map)))
          .toList(),
      skipped: ((d['skipped'] as List?) ?? const [])
          .map((s) => SkippedParty.fromMap(Map<String, dynamic>.from(s as Map)))
          .toList(),
      acknowledgedWarnings: d['acknowledgedWarnings'] == true,
      approvedByName: d['approvedByName'] as String?,
      approvedAt: (d['approvedAt'] as Timestamp?)?.toDate(),
      abortReasonHi: d['abortReasonHi'] as String?,
      staleReasonHi: d['staleReasonHi'] as String?,
      templateProblemHi: d['templateProblemHi'] as String?,
    );
  }

  bool get needsApproval => status == 'awaiting_approval';
  bool get isFinished => const {'done', 'cancelled', 'expired', 'aborted'}.contains(status);

  /// Ships in Hinglish, because the person reading it is the owner.
  String get statusHi => switch (status) {
    'building' => 'Ban raha hai…',
    'awaiting_approval' => 'Aapke approve ka intezaar',
    'approved' => 'Approve ho gaya — bhejna shuru',
    'sending' => 'Bheja ja raha hai…',
    'done' => 'Ho gaya',
    'cancelled' => 'Aapne cancel kar diya',
    'expired' => '48 ghante me approve nahi hua — purana ho gaya',
    'stale' => 'Aankde purane ho gaye — naya banwaiye',
    'aborted' => 'Rok diya gaya (hisaab match nahi hua)',
    _ => status,
  };
}

// ---------------------------------------------------------------------------
// outstanding_runs/{runId}/parties/{partyGuid}
// ---------------------------------------------------------------------------

class StatementBill {
  const StatementBill({
    required this.billRef,
    required this.billDateIso,
    required this.signedPaise,
    this.dueDateIso,
    this.creditDays = 0,
    this.ageDays,
    this.overdueDays,
    this.tallyOverdueDays,
    this.isAdvance = false,
  });

  final String billRef;
  final String billDateIso;

  /// ⚠️ **Debit is NEGATIVE.** A bill the customer owes us comes through as a
  /// negative number, all the way from the Tally TDL expression. The flip to
  /// "what he owes" happens once, in `duePaise`. `abs()` appears nowhere.
  final int signedPaise;
  final String? dueDateIso;
  final int creditDays;
  final int? ageDays;
  final int? overdueDays;
  final int? tallyOverdueDays;
  final bool isAdvance;

  bool get isCredit => signedPaise > 0;

  /// What the customer sees on that line, positive.
  int get displayPaise => -signedPaise;

  factory StatementBill.fromMap(Map<String, dynamic> m) => StatementBill(
    billRef: m['billRef'] as String? ?? '—',
    billDateIso: m['billDateIso'] as String? ?? '',
    signedPaise: (m['signedPaise'] as num?)?.toInt() ?? 0,
    dueDateIso: m['dueDateIso'] as String?,
    creditDays: (m['creditDays'] as num?)?.toInt() ?? 0,
    ageDays: (m['ageDays'] as num?)?.toInt(),
    overdueDays: (m['overdueDays'] as num?)?.toInt(),
    tallyOverdueDays: (m['tallyOverdueDays'] as num?)?.toInt(),
    isAdvance: m['isAdvance'] == true,
  );
}

class OutstandingParty {
  const OutstandingParty({
    required this.partyGuid,
    required this.partyName,
    required this.status,
    this.waId,
    this.mobileVerdict,
    this.mobileSource,
    this.duePaise = 0,
    this.billsSumPaise,
    this.ledgerClosingPaise,
    this.reconcileDiffPaise,
    this.bills = const [],
    this.billCount = 0,
    this.oldestDebitAgeDays,
    this.oldestDebitOverdueDays,
    this.caption,
    this.templateParams = const [],
    this.fileName,
    this.pdfPath,
    this.pdfSha256,
    this.channel,
    this.skipReasonHi,
    this.nameMismatchWarning = false,
    this.wamid,
    this.sentAt,
    this.fellBackToTemplate = false,
    this.error,
  });

  final String partyGuid;
  final String partyName;

  /// `candidate` · `excluded` · `skipped` · `approved_pending` · `sending`
  /// `sent` · `failed` · `reconcile_failed_server` · `blocked_no_template`
  /// `dry_run` · `cooldown`
  final String status;
  final String? waId;
  final String? mobileVerdict;
  final String? mobileSource;
  final int duePaise;
  final int? billsSumPaise;
  final int? ledgerClosingPaise;
  final int? reconcileDiffPaise;
  final List<StatementBill> bills;
  final int billCount;
  final int? oldestDebitAgeDays;
  final int? oldestDebitOverdueDays;
  final String? caption;

  /// ⚠️ The rendered **VALUES**, snapshotted — not a pointer. "Was it really
  /// ₹1,25,000 when we said so?" is a question asked three weeks later in a
  /// dispute, by which time Tally has moved on.
  final List<String> templateParams;
  final String? fileName;
  final String? pdfPath;
  final String? pdfSha256;
  final String? channel;
  final String? skipReasonHi;

  /// Surfaced, never enforced: staff rename a chat to "Rajubhai" while Tally
  /// says "SHREE KRISHNA TEXTILES", and it is the same man.
  final bool nameMismatchWarning;
  final String? wamid;
  final DateTime? sentAt;
  final bool fellBackToTemplate;
  final String? error;

  factory OutstandingParty.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return OutstandingParty(
      partyGuid: doc.id,
      partyName: d['partyName'] as String? ?? '—',
      status: d['status'] as String? ?? 'candidate',
      waId: d['waId'] as String?,
      mobileVerdict: d['mobileVerdict'] as String?,
      mobileSource: d['mobileSource'] as String?,
      duePaise: (d['duePaise'] as num?)?.toInt() ?? 0,
      billsSumPaise: (d['billsSumPaise'] as num?)?.toInt(),
      ledgerClosingPaise: (d['ledgerClosingPaise'] as num?)?.toInt(),
      reconcileDiffPaise: (d['reconcileDiffPaise'] as num?)?.toInt(),
      bills: ((d['bills'] as List?) ?? const [])
          .map((b) => StatementBill.fromMap(Map<String, dynamic>.from(b as Map)))
          .toList(),
      billCount: (d['billCount'] as num?)?.toInt() ?? 0,
      oldestDebitAgeDays: (d['oldestDebitAgeDays'] as num?)?.toInt(),
      oldestDebitOverdueDays: (d['oldestDebitOverdueDays'] as num?)?.toInt(),
      caption: d['caption'] as String?,
      templateParams: (d['templateParams'] as List?)?.cast<String>() ?? const [],
      fileName: d['fileName'] as String?,
      pdfPath: d['pdfPath'] as String?,
      pdfSha256: d['pdfSha256'] as String?,
      channel: d['channel'] as String?,
      skipReasonHi: d['skipReasonHi'] as String?,
      nameMismatchWarning: d['nameMismatchWarning'] == true,
      wamid: d['wamid'] as String?,
      sentAt: (d['sentAt'] as Timestamp?)?.toDate(),
      fellBackToTemplate: d['fellBackToTemplate'] == true,
      error: d['error'] as String?,
    );
  }

  bool get isIncludable => status == 'candidate' || status == 'approved_pending';
  bool get isExcluded => status == 'excluded';

  /// Will this one cost money? A session message inside the 24-hour window is
  /// free; a template is about ₹0.14 + GST.
  bool get willUseTemplate => channel == 'template';
}

// ---------------------------------------------------------------------------
// tally_parties/{ledgerGuid}
// ---------------------------------------------------------------------------

class TallyParty {
  const TallyParty({
    required this.ledgerGuid,
    required this.ledgerName,
    required this.mobileVerdict,
    this.mobileRaw,
    this.waId,
    this.mobileCandidates = const [],
    this.duplicateWith = const [],
    this.mobileOverride,
    this.overrideByName,
    this.overrideAt,
    this.doNotSend = false,
    this.doNotSendReason,
    this.gstin,
    this.contactPerson,
    this.lastStatementAt,
    this.lastStatementDuePaise,
  });

  final String ledgerGuid;
  final String ledgerName;
  final String mobileVerdict;
  final String? mobileRaw;
  final String? waId;
  final List<String> mobileCandidates;
  final List<String> duplicateWith;
  final String? mobileOverride;
  final String? overrideByName;
  final DateTime? overrideAt;
  final bool doNotSend;
  final String? doNotSendReason;
  final String? gstin;
  final String? contactPerson;
  final DateTime? lastStatementAt;
  final int? lastStatementDuePaise;

  factory TallyParty.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return TallyParty(
      ledgerGuid: doc.id,
      ledgerName: d['ledgerName'] as String? ?? '—',
      mobileVerdict: d['mobileVerdict'] as String? ?? 'MISSING',
      mobileRaw: d['mobileRaw'] as String?,
      waId: d['waId'] as String?,
      mobileCandidates: (d['mobileCandidates'] as List?)?.cast<String>() ?? const [],
      duplicateWith: (d['duplicateWith'] as List?)?.cast<String>() ?? const [],
      mobileOverride: d['mobileOverride'] as String?,
      overrideByName: d['overrideByName'] as String?,
      overrideAt: (d['overrideAt'] as Timestamp?)?.toDate(),
      doNotSend: d['doNotSend'] == true,
      doNotSendReason: d['doNotSendReason'] as String?,
      gstin: d['gstin'] as String?,
      contactPerson: d['contactPerson'] as String?,
      lastStatementAt: (d['lastStatementAt'] as Timestamp?)?.toDate(),
      lastStatementDuePaise: (d['lastStatementDuePaise'] as num?)?.toInt(),
    );
  }

  bool get canSend => mobileVerdict == 'OK' || mobileVerdict == 'OK_OVERRIDE';
}

/// The ten verdicts, and what to say about each one — matching
/// `functions/lib/tallyMobile.js` exactly.
abstract final class MobileVerdict {
  static const sendable = {'OK', 'OK_OVERRIDE'};

  static String hi(String? verdict) => switch (verdict) {
    'OK' => 'Number theek hai',
    'OK_OVERRIDE' => 'Number haath se set kiya gaya hai',
    'MISSING' => 'Tally ledger me mobile number khaali hai',
    'MALFORMED' => 'Tally me jo likha hai woh samajh nahi aaya',
    'AMBIGUOUS_MULTIPLE' => 'Ek se zyada number hain — kaunsa sahi hai, aap chuniye',
    'DUPLICATE_NUMBER' => 'Yehi number kisi doosri party par bhi laga hai',
    'FOREIGN' => 'Ye India ka number nahi lag raha',
    'SELF' => 'Ye apna hi number hai',
    'BLOCKED' => 'Is party ko bhejna band kiya gaya hai',
    'NO_CHAT_YET' => 'Inhone kabhi message nahi kiya — pehle whitelist karein',
    _ => 'Number ka masla hai',
  };

  static String fixHi(String? verdict) => switch (verdict) {
    'MISSING' => 'Tally ke ledger me mobile bhariye, ya yahin se number daal dijiye.',
    'MALFORMED' => 'Sahi 10 digit ka number yahin type kar dijiye.',
    'AMBIGUOUS_MULTIPLE' => 'Neeche se ek number par tap kijiye.',
    'DUPLICATE_NUMBER' => 'Dono ledger me se ek ka number Tally me theek kijiye.',
    'FOREIGN' => 'Agar ye sahi hai to yahin se number set kijiye.',
    'SELF' => 'Kuch karne ki zaroorat nahi.',
    'BLOCKED' => 'Chahein to yahin se dobara chalu kar sakte hain.',
    'NO_CHAT_YET' => "Ek baar 'Whitelist karein' dabaiye.",
    _ => '',
  };
}
