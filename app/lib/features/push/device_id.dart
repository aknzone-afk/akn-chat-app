import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _kDeviceIdKey = 'akn.deviceId';

/// A stable id for THIS install of the app on THIS phone.
///
/// It is what makes per-device push presence work: the backend has to be able
/// to say "the token on the phone that currently has this chat open" rather
/// than "any token belonging to this staff member", so the same person's second
/// handset still buzzes. An FCM token cannot play that role — it rotates.
///
/// Reinstalling the app mints a new one. That is correct: the old entry ages
/// out of `fcmTokens` on its own, and its token is dead anyway, so
/// `notifyInbound` prunes it on the first send.
String deviceIdOf(SharedPreferences prefs) {
  final existing = prefs.getString(_kDeviceIdKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final fresh = const Uuid().v4();
  // Fire and forget: a failed write just means a new id next launch, which
  // costs one stale array element that ages out by itself.
  prefs.setString(_kDeviceIdKey, fresh);
  return fresh;
}
