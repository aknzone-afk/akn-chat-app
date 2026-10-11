import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The loud channel. Its id MUST equal the
/// `com.google.firebase.messaging.default_notification_channel_id` meta-data in
/// AndroidManifest.xml, and the `channelId` that `functions/lib/push.js` puts
/// on every payload. Three places, one string.
const AndroidNotificationChannel kChatChannel = AndroidNotificationChannel(
  'chat_messages',
  'Naye message',
  // NAMED parameter since flutter_local_notifications 22 — it was positional
  // before, and the migration is silent if you are not watching.
  description: 'Customer ke naye WhatsApp message',
  importance: Importance.high, // .high or .max is what produces a heads-up
  playSound: true,
);

/// The quiet channel.
///
/// On Android 8+ sound and vibration are properties of the CHANNEL, not of the
/// message, so "same chat again within six seconds — do not buzz" cannot be a
/// payload flag. It has to be a second channel. `functions/lib/push.js` picks
/// between them.
const AndroidNotificationChannel kChatChannelSilent = AndroidNotificationChannel(
  'chat_messages_silent',
  'Naye message (chup)',
  description: 'Ek hi chat me lagatar aa rahe message',
  importance: Importance.low,
  playSound: false,
);

/// Phase 5. The escalation channel.
///
/// The bot has decided a human is needed — a rate question, a complaint, a
/// payment query. That has to be AUDIBLY different from "a customer sent a
/// photo", or it drowns in the same stream of ordinary buzzes and the whole
/// point of the triage is lost.
///
/// Max importance, and `functions/lib/push.js::sendAttentionPush` deliberately
/// IGNORES the quiet-follow-up window for it: that window exists so ten photos
/// do not buzz ten times, and an escalation is exactly what it must not
/// swallow. The push carries the SAME `tag`/`apns-collapse-id` as an ordinary
/// message for that chat, so it REPLACES the tray entry rather than adding a
/// second one — "distinctly pushed" must not also mean "buzzed twice".
const AndroidNotificationChannel kChatAttentionChannel =
    AndroidNotificationChannel(
      'chat_attention',
      'Dhyaan dein',
      description: 'Bot ne kaha ki is chat par insaan chahiye',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

/// Create both channels EAGERLY, in `main()`, before any message can arrive.
///
/// ⚠️ The ordering bug this exists to avoid: if the FCM SDK creates the first
/// notification channel while the app is in the BACKGROUND, Android suppresses
/// that notification and will not prompt for POST_NOTIFICATIONS until the app
/// is next opened — and those notifications are simply lost.
Future<void> createNotificationChannels() async {
  final android = localNotifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  if (android == null) return; // iOS: channels are an Android concept
  await android.createNotificationChannel(kChatChannel);
  await android.createNotificationChannel(kChatChannelSilent);
  await android.createNotificationChannel(kChatAttentionChannel);
}
