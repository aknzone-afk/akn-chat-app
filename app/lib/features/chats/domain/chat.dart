import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/format/formatters.dart';

/// The 24-hour WhatsApp customer-service window.
///
/// While it is open we may send free-form text and it costs nothing. Once it
/// shuts, WhatsApp only accepts an approved template — which this backend does
/// not implement — so `sendMessage` refuses outright.
class ReplyWindow {
  const ReplyWindow(this.expiresAt);

  final DateTime? expiresAt;

  bool isOpen(DateTime now) =>
      expiresAt != null && now.isBefore(expiresAt!);

  Duration remaining(DateTime now) {
    final e = expiresAt;
    if (e == null) return Duration.zero;
    final left = e.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The line under the contact's name in the chat header.
  String label(DateTime now) => isOpen(now)
      ? 'Free window: ${humanDuration(remaining(now))} baaki'
      : 'Window band — abhi paid template lagega (~₹0.14)';
}

class Chat {
  const Chat({
    required this.waId,
    String? customerWaId,
    this.phoneNumberId,
    this.name,
    this.profileName,
    this.phoneSavedName,
    this.lastMessageText,
    this.lastMessageAt,
    this.lastMessageType,
    this.unreadCount = 0,
    this.lastCustomerMsgAt,
    this.windowExpiresAt,
    this.botEnabled = true,
    this.botPausedUntil,
    this.needsAttention = false,
    this.attentionReason,
    this.pinned = false,
    this.migratedTo,
    this.migratedFrom,
  }) : customerWaId = customerWaId ?? waId;

  /// The chat document id — a KEY. For the main business number it is the
  /// customer's number; for any other number it is `<number>_<phoneNumberId>`.
  final String waId;

  /// The customer's actual WhatsApp number. Use this for anything shown.
  final String customerWaId;
  final String? phoneNumberId;
  final String? name;
  final String? profileName;

  /// The name saved in the WhatsApp Business app on the shop phone (coexistence
  /// app-state sync, 11-Oct-2026).
  final String? phoneSavedName;
  final String? lastMessageText;
  final DateTime? lastMessageAt;
  final String? lastMessageType;
  final int unreadCount;
  final DateTime? lastCustomerMsgAt;
  final DateTime? windowExpiresAt;
  final bool botEnabled;
  final DateTime? botPausedUntil;
  final bool needsAttention;

  /// Phase 5. WHY the bot pulled a human in — "Rate/discount ki baat",
  /// "Complaint", "Design nahi mila: 6540". Written by handlers/botReply.js.
  ///
  /// The old banner said only "look at this chat", which does not tell staff
  /// what they are looking for — and the "why" is the entire value of the
  /// bot's triage.
  final String? attentionReason;

  final bool pinned;
  final String? migratedTo;
  final String? migratedFrom;

  factory Chat.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    return Chat(
      waId: snap.id,
      customerWaId: _str(d['waId']) ?? snap.id.split('_').first,
      phoneNumberId: d['phoneNumberId'] as String?,
      name: _str(d['name']),
      profileName: _str(d['profileName']),
      phoneSavedName: _str(d['phoneSavedName']),
      lastMessageText: _str(d['lastMessageText']),
      lastMessageAt: _date(d['lastMessageAt']),
      lastMessageType: _str(d['lastMessageType']),
      unreadCount: _int(d['unreadCount']),
      lastCustomerMsgAt: _date(d['lastCustomerMsgAt']),
      windowExpiresAt: _date(d['windowExpiresAt']),
      botEnabled: d['botEnabled'] != false,
      botPausedUntil: _date(d['botPausedUntil']),
      needsAttention: d['needsAttention'] == true,
      attentionReason: _str(d['attentionReason']),
      pinned: d['pinned'] == true,
      migratedTo: _str(d['migratedTo']),
      migratedFrom: _str(d['migratedFrom']),
    );
  }

  ReplyWindow get window => ReplyWindow(windowExpiresAt);

  /// What staff read. `name` is theirs to edit; `profileName` is what the
  /// customer calls themselves; the number is the last resort.
  String get displayName {
    final n = name?.trim();
    if (n != null && n.isNotEmpty && n != customerWaId) return n;
    final p = profileName?.trim();
    if (p != null && p.isNotEmpty) return p;
    return prettyPhone(customerWaId);
  }

  bool get hasCustomName {
    final n = name?.trim();
    return n != null && n.isNotEmpty && n != customerWaId;
  }

  /// True while the bot is silenced for this chat.
  ///
  /// Set by `sendMessage.js` the moment ANY staff member sends a manual
  /// message: `botPausedUntil = now + settings.botPauseMinutes`. The bot must
  /// never talk over a human.
  bool botPaused(DateTime now) =>
      botPausedUntil != null && now.isBefore(botPausedUntil!);

  /// How much of the pause is left, for the banner's countdown.
  Duration botPauseRemaining(DateTime now) {
    final until = botPausedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The little glyph in front of the preview line.
  String? get previewIcon => switch (lastMessageType) {
    'image' => '📷',
    'video' => '🎥',
    'document' => '📄',
    // No entry for 'audio' on purpose. normalize.js already prefixes it —
    // "🎤 Voice message" or "🎵 Audio" — and the chat document only records
    // `lastMessageType: 'audio'`, not which of the two it was. Guessing 🎤 made
    // the startsWith de-duplication miss on a music file and the row rendered
    // "🎤  🎵 Audio".
    'sticker' => '😀',
    'location' => '📍',
    'contacts' => '👤',
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is Chat &&
      other.waId == waId &&
      other.name == name &&
      other.profileName == profileName &&
      other.phoneSavedName == phoneSavedName &&
      other.lastMessageText == lastMessageText &&
      other.lastMessageAt == lastMessageAt &&
      other.lastMessageType == lastMessageType &&
      other.unreadCount == unreadCount &&
      other.windowExpiresAt == windowExpiresAt &&
      other.botEnabled == botEnabled &&
      other.botPausedUntil == botPausedUntil &&
      other.needsAttention == needsAttention &&
      other.attentionReason == attentionReason &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(
    waId,
    name,
    profileName,
    phoneSavedName,
    lastMessageText,
    lastMessageAt,
    lastMessageType,
    unreadCount,
    windowExpiresAt,
    botEnabled,
    botPausedUntil,
    needsAttention,
    attentionReason,
    pinned,
  );
}

String? _str(Object? v) => v is String ? v : null;

DateTime? _date(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}
