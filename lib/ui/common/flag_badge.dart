import 'package:flutter/material.dart';

import '../../services/geo/flag_emoji.dart';

/// A country's flag — the emoji where the device can draw it, a two-letter
/// badge where it cannot.
///
/// Plenty of Chinese Android ROMs ship an emoji font with the
/// regional-indicator letters but WITHOUT the flag sequences, so 🇨🇳 comes
/// out as two tofu boxes reading "C N". [emojiFlagsSupported] detects that
/// once, by measuring a valid pair against an invalid one: when sequences
/// compose, 🇨🇳 is a single narrow glyph while 🇽🇿 stays two boxes; when they
/// don't, both are two boxes and measure the same.
class FlagBadge extends StatelessWidget {
  /// Country name as the geocoder returned it (Chinese or an alias).
  final String country;
  final double size;
  const FlagBadge({super.key, required this.country, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final code = isoCodeFor(country);
    if (code == null) {
      return SizedBox(width: size * 1.5, height: size);
    }
    if (emojiFlagsSupported) {
      return Text(flagEmojiForCode(code), style: TextStyle(fontSize: size));
    }
    final hue = (code.codeUnitAt(0) * 37 + code.codeUnitAt(1) * 11) % 360;
    final bg = HSLColor.fromAHSL(1, hue.toDouble(), 0.42, 0.42).toColor();
    return Container(
      width: size * 1.5,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.2),
        border: Border.all(color: Colors.white24, width: 0.5),
      ),
      child: Text(
        code,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.62,
          height: 1.0,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

bool? _supported;

/// Whether this device composes regional-indicator pairs into flags.
bool get emojiFlagsSupported => _supported ??= _detect();

bool _detect() {
  try {
    final valid = _width('\u{1F1E8}\u{1F1F3}'); // CN — a real flag
    final invalid = _width('\u{1F1FD}\u{1F1FF}'); // XZ — no such country
    if (valid <= 0 || invalid <= 0) return false;
    return valid < invalid * 0.9;
  } catch (_) {
    return false;
  }
}

double _width(String s) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: const TextStyle(fontSize: 24)),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}
