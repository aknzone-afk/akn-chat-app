import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The number on the iOS app icon.
///
/// `functions/lib/push.js` sets `aps.badge = totalUnread` on every push, which
/// can only ever RAISE it — a push arrives precisely when the count is above
/// zero. Nothing brought it back down, so a night's twelve unread messages, read
/// the next morning, left a "12" sitting on the icon until an unrelated customer
/// happened to write.
///
/// Android is deliberately excluded: launcher badges there are OEM-specific
/// (Samsung, Xiaomi and Nova all use different broadcasts), the FCM payload's
/// `notificationCount` already drives the ones that support it, and the
/// alternative is a dependency for a cosmetic nicety.
abstract final class AppBadge {
  static const MethodChannel _channel = MethodChannel('akn/badge');

  /// Last value pushed across the channel. Skipping unchanged values keeps this
  /// off the platform thread on every chat-list snapshot.
  static int? _last;

  static Future<void> set(int count) async {
    if (!Platform.isIOS) return;
    final value = count < 0 ? 0 : count;
    if (_last == value) return;
    _last = value;
    try {
      await _channel.invokeMethod<void>('set', value);
    } catch (e) {
      // A badge is a nicety. An older build of the host app that has no handler
      // registered must never take the chat list down with it.
      _last = null;
      debugPrint('badge set failed: $e');
    }
  }
}
