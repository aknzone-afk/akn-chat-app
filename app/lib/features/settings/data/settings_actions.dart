import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure.dart';
import '../../../core/firebase/firebase_providers.dart';

/// The only write path to `settings/app`.
///
/// `firestore.rules` keeps that document `allow write: if false` for every
/// client, so every one of these goes through the `updateSettings` callable,
/// which re-validates against a strict whitelist and refuses anything not on
/// it. `geminiPersona`, `botGlobalEnabled` and `ownerNumbers` additionally
/// require `staff/{uid}.owner == true` — checked on the SERVER; the app only
/// hides the controls so nobody taps something that would be refused.
class SettingsActions {
  SettingsActions(this._ref);

  final Ref _ref;

  FirebaseFunctions get _functions => _ref.read(functionsProvider);

  Future<void> _update(Map<String, Object?> patch) => callGuarded(
    () => _functions
        .httpsCallable(
          'updateSettings',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call<Map<String, dynamic>?>({'patch': patch}),
  );

  /// Rewrite the bot's persona. An EMPTY string asks the backend to put the
  /// shipped default back — that is what the "Wapas default par le jaayein"
  /// button sends.
  Future<void> setPersona(String persona) =>
      _update({'geminiPersona': persona});

  /// Arm or disarm the bot for every chat at once.
  ///
  /// ⚠️ Do not turn this on until billing is attached to the Gemini API key.
  /// Google's free tier uses prompts to improve their products, and the
  /// WhatsApp Business Solution Terms forbid Business Solution Data being used
  /// to train AI. The free tier's ~250 requests a day would not run this bot
  /// anyway.
  Future<void> setBotGlobalEnabled(bool enabled) =>
      _update({'botGlobalEnabled': enabled});

  /// How long the bot stays quiet after any staff member sends a message.
  Future<void> setBotPauseMinutes(int minutes) =>
      _update({'botPauseMinutes': minutes});

  /// Refuse to quote a price older than this many days. 0 = never refuse.
  Future<void> setProductPriceMaxAgeDays(int days) =>
      _update({'productPriceMaxAgeDays': days});

  /// At most this many bot replies per chat per 10 minutes.
  Future<void> setBotReplyMaxPer10Min(int n) =>
      _update({'botReplyMaxPer10Min': n});

  /// Prefix the first bot message of each 24-hour window with
  /// "AKN ZONE — auto reply".
  Future<void> setBotDisclosure(bool on) => _update({'botDisclosure': on});

  Future<void> setSendReadReceipts(bool on) =>
      _update({'sendReadReceipts': on});

  Future<void> setQuickReplies(List<String> replies) =>
      _update({'quickReplies': replies});
}

final settingsActionsProvider = Provider<SettingsActions>(SettingsActions.new);
