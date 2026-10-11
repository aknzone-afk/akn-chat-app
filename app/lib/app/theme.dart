import 'package:flutter/material.dart';

/// AKN ZONE's colours. Maroon and gold on the chrome; WhatsApp's own bubble
/// palette inside the conversation, because "zero retraining" beats "on brand"
/// at the exact place staff read a hundred messages an hour.
abstract final class AknColors {
  static const maroon = Color(0xFF6B1E2E);
  static const maroonDark = Color(0xFF4C1421);
  static const maroonLight = Color(0xFF8E3145);
  static const gold = Color(0xFFC9A227);
  static const goldSoft = Color(0xFFE8CE7A);

  // Conversation
  static const wallpaperLight = Color(0xFFECE5DD);
  static const wallpaperDark = Color(0xFF0B141A);
  static const outBubbleLight = Color(0xFFD9FDD3);
  static const outBubbleDark = Color(0xFF124C39);
  static const inBubbleLight = Color(0xFFFFFFFF);
  static const inBubbleDark = Color(0xFF1F2C34);

  /// The BOT's outgoing bubble — the WhatsApp green shifted toward slate.
  ///
  /// Deliberately close enough to the staff bubble that the thread still reads
  /// as one conversation, and different enough that a glance down it separates
  /// machine from human without reading a word. Staff have to be able to see
  /// what the bot said, at speed, without hunting for a label.
  static const botBubbleLight = Color(0xFFD6E9F2);
  static const botBubbleDark = Color(0xFF16414F);

  /// The "Bot band hai — staff reply kar raha hai" strip. Slate-blue, so it is
  /// never confused with the amber attention strip sitting right under it.
  static const botPausedLight = Color(0xFFDCEBF5);
  static const botPausedDark = Color(0xFF17323F);
  static const botPausedInk = Color(0xFF0E5C7A);
  static const botPausedInkDark = Color(0xFF9CD4EC);

  // Ticks
  static const tickGrey = Color(0xFF8696A0);
  static const tickBlue = Color(0xFF53BDEB);
  static const tickRed = Color(0xFFE5544B);

  // Window dot
  static const windowOpen = Color(0xFF25D366);
  static const windowClosed = Color(0xFF9AA5AB);

  // Attention strip
  static const attentionLight = Color(0xFFFFF3CD);
  static const attentionDark = Color(0xFF4A3A0E);
  static const attentionInk = Color(0xFF8A6100);

  /// The same ink lifted for dark surfaces. Named here because three separate
  /// widgets were each hard-coding it (and one of them was not).
  static const attentionInkDark = Color(0xFFF3D98A);
}

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: AknColors.maroon,
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFF3DDE2),
  onPrimaryContainer: AknColors.maroonDark,
  secondary: AknColors.gold,
  onSecondary: Color(0xFF2A2000),
  secondaryContainer: Color(0xFFFBEFC9),
  onSecondaryContainer: Color(0xFF3D2E00),
  tertiary: Color(0xFF1B7F5A),
  onTertiary: Colors.white,
  error: Color(0xFFB3261E),
  onError: Colors.white,
  surface: Color(0xFFFDFBF8),
  onSurface: Color(0xFF1B1717),
  surfaceContainerHighest: Color(0xFFEFE7E4),
  onSurfaceVariant: Color(0xFF534344),
  outline: Color(0xFF857374),
  outlineVariant: Color(0xFFD8C2C4),
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFB8455C),
  onPrimary: Color(0xFF3A0A16),
  primaryContainer: Color(0xFF5A1826),
  onPrimaryContainer: Color(0xFFFFD9DF),
  secondary: AknColors.goldSoft,
  onSecondary: Color(0xFF3A2E00),
  secondaryContainer: Color(0xFF544300),
  onSecondaryContainer: Color(0xFFFFE08A),
  tertiary: Color(0xFF6FDBAE),
  onTertiary: Color(0xFF00382A),
  error: Color(0xFFF2B8B5),
  onError: Color(0xFF601410),
  surface: Color(0xFF121B1F),
  onSurface: Color(0xFFE6E1E1),
  surfaceContainerHighest: Color(0xFF243138),
  onSurfaceVariant: Color(0xFFB4C0C6),
  outline: Color(0xFF7F8B91),
  outlineVariant: Color(0xFF3A474D),
);

ThemeData _base(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? const Color(0xFF1B262C) : AknColors.maroon,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 2,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      iconTheme: const IconThemeData(color: Colors.white, size: 22),
      actionsIconTheme: const IconThemeData(color: Colors.white, size: 22),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.6),
      space: 1,
      thickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: 8,
      horizontalTitleGap: 12,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: isDark ? const Color(0xFF2A3942) : Colors.white,
      foregroundColor: isDark ? Colors.white70 : AknColors.maroon,
      elevation: 3,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    ),
  );
}

final ThemeData aknLightTheme = _base(_lightScheme);
final ThemeData aknDarkTheme = _base(_darkScheme);

// ---------------------------------------------------------------------------
// Conversation tokens
//
// Everything below is hoisted to a top-level `const`/`final` on purpose. A
// `BoxDecoration` or `TextStyle` rebuilt inside `build()` defeats
// `RenderDecoratedBox`'s equality short-circuit and forces a repaint of every
// visible bubble on every frame.
// ---------------------------------------------------------------------------

/// Bubble geometry, shared by the bubble and by anything that measures it.
abstract final class Bubbles {
  static const maxWidthFactor = 0.78;
  static const padding = EdgeInsets.fromLTRB(9, 6, 9, 7);
  static const radius = Radius.circular(9);
  static const tightRadius = Radius.circular(3);
  static const gap = 2.0;
  static const groupGap = 8.0;
}

const kMetaTextStyleLight = TextStyle(
  fontSize: 11,
  height: 1.0,
  color: Color(0xFF667781),
  fontFeatures: [FontFeature.tabularFigures()],
);

const kMetaTextStyleDark = TextStyle(
  fontSize: 11,
  height: 1.0,
  color: Color(0xFF9BB0BB),
  fontFeatures: [FontFeature.tabularFigures()],
);

const kBubbleTextLight = TextStyle(
  fontSize: 15.5,
  height: 1.32,
  color: Color(0xFF111B21),
);

const kBubbleTextDark = TextStyle(
  fontSize: 15.5,
  height: 1.32,
  color: Color(0xFFE9EDEF),
);

/// The conversation background. Painted, not shipped as an asset.
BoxDecoration chatWallpaper(Brightness brightness) => brightness == Brightness.dark
    ? const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0C1A20), AknColors.wallpaperDark],
        ),
      )
    : const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF1EBE3), AknColors.wallpaperLight],
        ),
      );

Color outBubbleColor(Brightness b) =>
    b == Brightness.dark ? AknColors.outBubbleDark : AknColors.outBubbleLight;

/// The bubble colour for one of OUR messages, given who wrote it.
/// `from` is 'staff' | 'owner-cmd' | 'bot' — and firestore.rules makes 'bot'
/// unforgeable from a phone, so this is a fact, not a guess.
Color outgoingBubbleColor(Brightness b, String? from) => from == 'bot'
    ? (b == Brightness.dark ? AknColors.botBubbleDark : AknColors.botBubbleLight)
    : outBubbleColor(b);

Color inBubbleColor(Brightness b) =>
    b == Brightness.dark ? AknColors.inBubbleDark : AknColors.inBubbleLight;

TextStyle bubbleTextStyle(Brightness b) =>
    b == Brightness.dark ? kBubbleTextDark : kBubbleTextLight;

TextStyle metaTextStyle(Brightness b) =>
    b == Brightness.dark ? kMetaTextStyleDark : kMetaTextStyleLight;
