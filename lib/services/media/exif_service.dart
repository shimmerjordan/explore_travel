import 'dart:io';
import 'package:exif/exif.dart';

class ExifGps {
  final double lat;
  final double lng;
  final DateTime? time;
  ExifGps({required this.lat, required this.lng, this.time});
}

/// Reads GPS coordinates from a photo's EXIF metadata. Returns null if the
/// file has no GPS tags or can't be parsed.
class ExifService {
  static Future<ExifGps?> readGps(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return null;

      final lat = _coord(tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef']);
      final lng =
          _coord(tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef']);
      if (lat == null || lng == null) return null;

      DateTime? time;
      final dt = tags['EXIF DateTimeOriginal']?.printable ??
          tags['Image DateTime']?.printable;
      if (dt != null) {
        // Format: "2024:05:01 12:34:56"
        try {
          final iso = dt.replaceFirst(':', '-').replaceFirst(':', '-');
          time = DateTime.tryParse(iso.replaceFirst(' ', 'T'));
        } catch (_) {}
      }
      return ExifGps(lat: lat, lng: lng, time: time);
    } catch (_) {
      return null;
    }
  }

  static double? _coord(IfdTag? coord, IfdTag? ref) {
    if (coord == null) return null;
    final values = coord.values;
    if (values.length < 3) return null;
    double toD(dynamic v) {
      if (v is Ratio) return v.numerator / v.denominator;
      if (v is num) return v.toDouble();
      return 0;
    }

    final list = values.toList();
    final d = toD(list[0]) + toD(list[1]) / 60 + toD(list[2]) / 3600;
    final r = ref?.printable.trim().toUpperCase();
    if (r == 'S' || r == 'W') return -d;
    return d;
  }
}
