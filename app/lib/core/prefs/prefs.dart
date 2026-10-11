import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in `main()` once SharedPreferences has loaded, so nothing in the
/// app ever has to await it.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider was not overridden'),
);

const _kThemeModeKey = 'akn.themeMode';
const _kDraftPrefix = 'akn.draft.';

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final raw = ref.read(sharedPreferencesProvider).getString(_kThemeModeKey);
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_kThemeModeKey, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

/// Per-chat composer drafts, on-device only.
///
/// This is deliberately NOT the provider the message list watches — the draft
/// text lives in the composer's own `TextEditingController` and reaches here
/// exactly once, in `dispose()`. Putting live draft text into shared state is
/// the single most common chat performance bug: every keystroke would rebuild
/// every visible bubble.
class DraftsController extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final out = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_kDraftPrefix)) continue;
      final value = prefs.getString(key);
      if (value != null && value.isNotEmpty) {
        out[key.substring(_kDraftPrefix.length)] = value;
      }
    }
    return out;
  }

  String? read(String waId) => state[waId];

  void save(String waId, String text) {
    final prefs = ref.read(sharedPreferencesProvider);
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      if (!state.containsKey(waId)) return;
      state = {...state}..remove(waId);
      prefs.remove('$_kDraftPrefix$waId');
      return;
    }
    if (state[waId] == trimmed) return;
    state = {...state, waId: trimmed};
    prefs.setString('$_kDraftPrefix$waId', trimmed);
  }
}

final draftsProvider = NotifierProvider<DraftsController, Map<String, String>>(
  DraftsController.new,
);
