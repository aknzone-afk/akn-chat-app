import 'package:cloud_firestore/cloud_firestore.dart';

/// One row of `bot_logs` — everything the bot did, or deliberately did not do,
/// for ONE inbound customer message.
///
/// The document id IS the inbound message's id, which is what lets the
/// "Ye reply kyun?" sheet be a single `doc().get()` with no index and no query.
///
/// Written once by `handlers/botReply.js` and patched exactly once with the
/// outcome. Read-only here: firestore.rules says `bot_logs: allow write: if
/// false`.
class BotLog {
  const BotLog({
    required this.id,
    this.waId,
    this.ts,
    this.route,
    this.suppressedReason,
    this.action,
    this.intent,
    this.confidence,
    this.matchedPattern,
    this.escalationRule,
    this.escalationMatched,
    this.templateId,
    this.inboundText,
    this.normalizedText,
    this.outboundText,
    this.attentionReason,
    this.billRequestId,
    this.needsAttentionSet = false,
    this.egressPassed = true,
    this.egressBlocked = const [],
    this.retrieval,
    this.aiCalls = const [],
    this.totalTokens = 0,
    this.totalCostInr = 0,
    this.durationMs,
    this.settleMs,
    this.chatName,
  });

  final String id;
  final String? waId;
  final DateTime? ts;

  /// How the answer was reached: `regex` (free), `llm` (cost money),
  /// `escalated`, `suppressed`, `skipped`, `owner_command`, `error`.
  final String? route;

  /// Why nothing was sent. This is the field that answers the question staff
  /// actually ask, which is "why did the bot NOT reply?".
  final String? suppressedReason;

  /// `replied` | `no_reply` | `attention_only`
  final String? action;

  final String? intent;
  final double? confidence;
  final String? matchedPattern;
  final String? escalationRule;
  final String? escalationMatched;
  final String? templateId;

  final String? inboundText;
  final String? normalizedText;
  final String? outboundText;
  final String? attentionReason;
  final String? billRequestId;
  final bool needsAttentionSet;

  final bool egressPassed;
  final List<String> egressBlocked;

  /// The VALUES the bot read out of the catalogue, not a pointer to them.
  /// "Was it really ₹340 when we said so?" is asked three weeks later, by which
  /// time `products/6540` has been re-imported twice.
  final Map<String, dynamic>? retrieval;

  final List<BotAiCall> aiCalls;
  final int totalTokens;
  final double totalCostInr;
  final int? durationMs;
  final int? settleMs;
  final String? chatName;

  bool get usedAi => aiCalls.isNotEmpty;
  bool get replied => action == 'replied';

  factory BotLog.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    final esc = d['escalation'];
    final egress = d['egressCheck'];

    return BotLog(
      id: snap.id,
      waId: d['waId'] as String?,
      ts: _date(d['ts']),
      route: d['route'] as String?,
      suppressedReason: d['suppressedReason'] as String?,
      action: d['action'] as String?,
      intent: d['intent'] as String?,
      confidence: _double(d['confidence']),
      matchedPattern: d['matchedPattern'] as String?,
      escalationRule: esc is Map ? esc['rule'] as String? : null,
      escalationMatched: esc is Map ? esc['matched'] as String? : null,
      templateId: d['templateId'] as String?,
      inboundText: d['inboundText'] as String?,
      normalizedText: d['normalizedText'] as String?,
      outboundText: d['outboundText'] as String?,
      attentionReason: d['attentionReason'] as String?,
      billRequestId: d['billRequestId'] as String?,
      needsAttentionSet: d['needsAttentionSet'] == true,
      egressPassed: egress is Map ? egress['passed'] != false : true,
      egressBlocked: egress is Map && egress['blocked'] is List
          ? (egress['blocked'] as List).map((e) => e.toString()).toList()
          : const [],
      retrieval: d['retrieval'] is Map
          ? Map<String, dynamic>.from(d['retrieval'] as Map)
          : null,
      aiCalls: d['aiCalls'] is List
          ? (d['aiCalls'] as List)
                .whereType<Map>()
                .map(BotAiCall.fromMap)
                .toList(growable: false)
          : const [],
      totalTokens: _int(d['totalTokens']) ?? 0,
      totalCostInr: _double(d['totalCostInr']) ?? 0,
      durationMs: _int(d['durationMs']),
      settleMs: _int(d['settleMs']),
      chatName: d['chatName'] as String?,
    );
  }

  /// One line, in Hinglish, saying what happened. Used on the activity list.
  String get headline {
    if (action == 'replied') {
      return switch (templateId) {
        'DESIGN_PRICE' => 'Design ka rate bheja',
        'BILL_QUEUED' => 'Bill queue me daala',
        'BILL_WHICH' => 'Bill number pucha',
        'DESIGN_WHICH' => 'Design number pucha',
        'DESIGN_UNKNOWN' => 'Design nahi mila — team ko bola',
        'GREETING' => 'Namaste kaha',
        'COMPOSED' => 'Chhota jawab diya',
        _ => 'Jawab bheja',
      };
    }
    if (action == 'attention_only') {
      return attentionReason ?? 'Insaan ko bulaya';
    }
    return switch (suppressedReason) {
      'bot_global_off' => 'Bot globally band tha',
      'chat_bot_off' => 'Is chat me bot band hai',
      'paused' => 'Staff reply kar raha tha',
      'window_closed' => '24 ghante ka window band tha',
      'stale_message' => 'Message bahut purana tha',
      'superseded' => 'Customer ne aur message bheja',
      'not_text' => 'Text message nahi tha',
      'ack_only' => 'Sirf "ok" tha — jawab ki zaroorat nahi',
      'owner_message' => 'Owner ka message tha',
      'human-spoke' => 'Bhejte waqt staff ne reply kar diya',
      'bot-paused' => 'Bhejte waqt bot pause ho gaya',
      'rate_limit_10m' => 'Limit — 10 minute me 3 se zyada',
      'rate_limit_24h' => 'Limit — 24 ghante me bahut zyada',
      'rate_limit_gap' => 'Do reply ke beech ka gap kam tha',
      'egress_blocked' => '⚠️ Bot number bhejne ja raha tha — roka gaya',
      'send_failed' => 'WhatsApp ne message nahi liya',
      'low_confidence' => 'Bot ko theek se samajh nahi aaya',
      'human_needed' => 'Insaan chahiye tha',
      'classify_failed' => 'AI jawab nahi de paayi',
      'compose_failed' => 'AI jawab nahi bana paayi',
      'gemini_quota_exhausted' => '⚠️ Gemini ka quota khatam — billing lagayein',
      'crashed' => 'Bot me error aayi',
      _ => 'Kuch nahi bheja',
    };
  }
}

/// One Gemini call. There are 0, 1 or 2 per turn — and a call that FAILED is
/// logged too, because you are billed for blocked and truncated responses.
class BotAiCall {
  const BotAiCall({
    required this.purpose,
    this.model,
    this.promptVersion,
    this.latencyMs,
    this.attempts,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.thoughtTokens = 0,
    this.totalTokens = 0,
    this.costInr = 0,
    this.finishReason,
    this.blockReason,
    this.errorMessage,
  });

  /// `classify` or `compose`.
  final String purpose;
  final String? model;
  final String? promptVersion;
  final int? latencyMs;
  final int? attempts;
  final int inputTokens;
  final int outputTokens;
  final int thoughtTokens;
  final int totalTokens;
  final double costInr;
  final String? finishReason;
  final String? blockReason;
  final String? errorMessage;

  bool get failed => errorMessage != null;

  factory BotAiCall.fromMap(Map<dynamic, dynamic> m) {
    final err = m['error'];
    return BotAiCall(
      purpose: (m['purpose'] as String?) ?? 'call',
      model: m['model'] as String?,
      promptVersion: m['promptVersion'] as String?,
      latencyMs: _int(m['latencyMs']),
      attempts: _int(m['attempts']),
      inputTokens: _int(m['inputTokens']) ?? 0,
      outputTokens: _int(m['outputTokens']) ?? 0,
      thoughtTokens: _int(m['thoughtTokens']) ?? 0,
      totalTokens: _int(m['totalTokens']) ?? 0,
      costInr: _double(m['costInr']) ?? 0,
      finishReason: m['finishReason'] as String?,
      blockReason: m['blockReason'] as String?,
      // The HTTP status is the difference between "the model was confused" and
      // "you are out of quota" — 429 is the whole story of a bad afternoon, and
      // reading only `message` threw it away before it reached the audit sheet.
      errorMessage: _errorLine(err),
    );
  }
}

/// "429 · Resource exhausted" rather than just "Resource exhausted".
///
/// The HTTP status is the difference between "the model was confused" and "you
/// are out of quota" — 429 is the whole story of a bad afternoon, and reading
/// only `message` threw it away before it ever reached the audit sheet. Returns
/// null (not "") when there is no error, because `failed` keys off that.
String? _errorLine(Object? err) {
  if (err is! Map) return null;
  final parts = [
    err['status'],
    err['message'],
  ].where((e) => e != null && '$e'.isNotEmpty).map((e) => '$e');
  final line = parts.join(' · ');
  return line.isEmpty ? null : line;
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

double? _double(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return null;
}
