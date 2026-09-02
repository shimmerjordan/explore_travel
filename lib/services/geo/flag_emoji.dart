import '../../data/iso_countries.dart';

/// Country name (Chinese, or one of the aliases the geocoders return) → the
/// flag emoji, built from the ISO-3166-1 alpha-2 code in
/// [kContinents] — two regional-indicator code points, no image assets.
///
/// Returns an empty string when the name is unknown ('未知', an empty
/// string, a province mistaken for a country), so callers can just
/// concatenate.
String flagEmojiFor(String countryName) {
  final code = isoCodeFor(countryName);
  return code == null ? '' : flagEmojiForCode(code);
}

/// ISO alpha-2 → 🇨🇳-style emoji. Assumes a well-formed 2-letter code.
String flagEmojiForCode(String code) {
  if (code.length != 2) return '';
  const base = 0x1F1E6; // REGIONAL INDICATOR SYMBOL LETTER A
  final up = code.toUpperCase();
  final a = up.codeUnitAt(0), b = up.codeUnitAt(1);
  if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return '';
  return String.fromCharCodes([base + (a - 0x41), base + (b - 0x41)]);
}

Map<String, String>? _byName;

/// The name → code table, built once from [kContinents] (name + aliases).
String? isoCodeFor(String countryName) {
  final n = countryName.trim();
  if (n.isEmpty || n == '未知') return null;
  final table = _byName ??= _build();
  final hit = table[n];
  if (hit != null) return hit;
  // Geocoders sometimes return a longer form ('中华人民共和国香港特别行政区',
  // "People's Republic of China"). Fall back to a known name the string
  // contains: longest wins, and on a tie the one further right — Chinese
  // addresses run general → specific, so 中国香港 is 香港.
  String? best;
  var bestLen = 0, bestAt = -1;
  for (final e in table.entries) {
    final at = n.lastIndexOf(e.key);
    if (at < 0) continue;
    if (e.key.length > bestLen || (e.key.length == bestLen && at > bestAt)) {
      best = e.value;
      bestLen = e.key.length;
      bestAt = at;
    }
  }
  return best;
}

Map<String, String> _build() {
  final m = <String, String>{};
  for (final list in kContinents.values) {
    for (final c in list) {
      m[c.name] = c.code;
      m[c.code] = c.code;
      for (final a in c.aliases) {
        m.putIfAbsent(a, () => c.code);
      }
    }
  }
  return m;
}
