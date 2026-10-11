import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

final NumberFormat _inr = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

final NumberFormat _inrWhole = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 0,
);

/// Indian grouping — ₹1,23,456.78, not ₹123,456.78.
String formatInr(num value, {bool decimals = true}) =>
    (decimals ? _inr : _inrWhole).format(value);

// ---------------------------------------------------------------------------
// Clocks and calendars
// ---------------------------------------------------------------------------

final DateFormat _hhmm = DateFormat('h:mm a');
final DateFormat _dayMonth = DateFormat('d MMM');
final DateFormat _dayMonthYear = DateFormat('d MMM yyyy');
final DateFormat _weekday = DateFormat('EEEE');

/// Compare *local civil days*. Never compare UTC, and never compare
/// `toString()` prefixes — both are wrong across a DST or timezone change.
bool isSameLocalDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

int _daysBetweenLocal(DateTime a, DateTime b) {
  final la = DateTime(a.toLocal().year, a.toLocal().month, a.toLocal().day);
  final lb = DateTime(b.toLocal().year, b.toLocal().month, b.toLocal().day);
  return lb.difference(la).inDays;
}

/// The chat-list right-hand column: today → time, yesterday → "Kal",
/// this week → weekday, older → date.
String chatListTime(DateTime when, [DateTime? nowOverride]) {
  final now = nowOverride ?? DateTime.now();
  final diff = _daysBetweenLocal(when, now);
  if (diff == 0) return _hhmm.format(when.toLocal());
  if (diff == 1) return 'Kal';
  if (diff < 7) return _weekday.format(when.toLocal());
  if (when.toLocal().year == now.year) return _dayMonth.format(when.toLocal());
  return _dayMonthYear.format(when.toLocal());
}

/// The chip that floats above the first message of each day.
String dateChipLabel(DateTime when, [DateTime? nowOverride]) {
  final now = nowOverride ?? DateTime.now();
  final diff = _daysBetweenLocal(when, now);
  if (diff == 0) return 'Aaj';
  if (diff == 1) return 'Kal';
  if (diff < 7) return _weekday.format(when.toLocal());
  if (when.toLocal().year == now.year) return _dayMonth.format(when.toLocal());
  return _dayMonthYear.format(when.toLocal());
}

/// The time under a message bubble.
String bubbleTime(DateTime when) => _hhmm.format(when.toLocal());

// ---------------------------------------------------------------------------
// The 24-hour window countdown
// ---------------------------------------------------------------------------

/// "17h 42m", "42m", "3m" — never "0h 0m", never a negative.
String humanDuration(Duration d) {
  if (d.isNegative) return '0m';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '<1m';
}

// ---------------------------------------------------------------------------
// Phone numbers
// ---------------------------------------------------------------------------

/// A waId is digits only, with the country code — "919876543210".
/// Shown as "+91 98765 43210".
String prettyPhone(String waId) {
  final digits = waId.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 12 && digits.startsWith('91')) {
    final rest = digits.substring(2);
    return '+91 ${rest.substring(0, 5)} ${rest.substring(5)}';
  }
  if (digits.length > 10) {
    final cc = digits.substring(0, digits.length - 10);
    final rest = digits.substring(digits.length - 10);
    return '+$cc ${rest.substring(0, 5)} ${rest.substring(5)}';
  }
  return '+$digits';
}

/// Up to two letters for the avatar. Falls back to the last two digits of the
/// number, which is what staff actually recognise when a contact has no name.
String initialsFor(String displayName, String waId) {
  final cleaned = displayName.trim();
  final looksLikeNumber = RegExp(r'^[+\d\s-]+$').hasMatch(cleaned);

  if (cleaned.isNotEmpty && !looksLikeNumber) {
    final words = cleaned
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length >= 2) {
      return (words[0][0] + words[1][0]).toUpperCase();
    }
    return words.first.characters2(2).toUpperCase();
  }

  final digits = waId.replaceAll(RegExp(r'\D'), '');
  if (digits.length >= 2) return digits.substring(digits.length - 2);
  return digits.isEmpty ? '#' : digits;
}

extension on String {
  /// `substring` that cannot throw and does not split a surrogate pair.
  String characters2(int max) {
    final runes = this.runes.toList();
    if (runes.length <= max) return this;
    return String.fromCharCodes(runes.take(max));
  }
}
