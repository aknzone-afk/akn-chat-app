import 'package:flutter/material.dart';

import '../format/formatters.dart';

/// Initials on a colour derived from the waId, so the same customer always
/// gets the same colour on all four phones.
class AvatarInitials extends StatelessWidget {
  const AvatarInitials({
    super.key,
    required this.displayName,
    required this.waId,
    this.size = 48,
  });

  final String displayName;
  final String waId;
  final double size;

  static const _palette = <Color>[
    Color(0xFF6B1E2E),
    Color(0xFF1B7F5A),
    Color(0xFF2A5C8A),
    Color(0xFF8A5A1B),
    Color(0xFF5B3A8E),
    Color(0xFF8A2B4E),
    Color(0xFF1F6E6E),
    Color(0xFF7A4B12),
  ];

  Color get _color {
    var hash = 0;
    for (final c in waId.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    return _palette[hash % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = _color;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark
            ? Color.alphaBlend(base.withValues(alpha: 0.55), const Color(0xFF16232A))
            : base,
        shape: BoxShape.circle,
      ),
      child: Text(
        initialsFor(displayName, waId),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
