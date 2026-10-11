import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs/prefs.dart';
import 'device_id.dart';
import 'push_service.dart';

final deviceIdProvider = Provider<String>(
  (ref) => deviceIdOf(ref.watch(sharedPreferencesProvider)),
);

final pushServiceProvider = Provider<PushService>(PushService.new);

/// A chat waiting to be opened because a notification was tapped.
///
/// It is HELD rather than acted on immediately, because a tap can arrive before
/// the session is ready — a cold start from a terminated app, with an expired
/// token that needs a refresh round trip. Dropping it there would mean tapping
/// a customer's message and landing on the chat list.
class PendingDeepLink extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String waId) {
    if (waId.isEmpty) return;
    state = waId;
  }

  void clear() => state = null;
}

final pendingDeepLinkProvider = NotifierProvider<PendingDeepLink, String?>(
  PendingDeepLink.new,
);

/// Which chat is on screen on THIS device, and whether the app is foregrounded.
///
/// Mirrored into `staff/{uid}.fcmTokens[].openChat` so the backend can skip the
/// push — and kept locally as well, because `onMessage` uses it to decide
/// whether to render a heads-up, which covers the ~200 ms race where somebody
/// opens a chat at the exact moment a message lands.
class OpenChat extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? waId) => state = waId;
}

final openChatProvider = NotifierProvider<OpenChat, String?>(OpenChat.new);
