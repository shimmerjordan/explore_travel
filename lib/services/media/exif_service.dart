import 'dart:io';
import 'package:exif/exif.dart';
import 'package:permission_handler/permission_handler.dart';

class ExifGps {
  final double lat;
  final double lng;
  final DateTime? time;
  ExifGps({required this.lat, required this.lng, this.time});
}

/// Everything EXIF can tell us about *where and when*: either half may be
/// missing. A photo with a time but no GPS is the common case for shared /
/// screenshot-cleaned images — and exactly the case the track interpolator
/// can rescue, so [readGps] (which needs both) is no longer the only door.
class ExifMeta {
  final double? lat;
  final double? lng;
  final DateTime? time;
  const ExifMeta({this.lat, this.lng, this.time});
  bool get hasGps => lat != null && lng != null;
}

/// Reads GPS coordinates from a photo's EXIF metadata. Returns null if the
/// file has no GPS tags or can't be parsed.
class ExifService {
  /// GPS and/or capture time — whichever the file carries. Null only when
  /// the file has no EXIF at all (or can't be parsed).
  static Future<ExifMeta?> readMeta(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return null;
      final lat = _coord(tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef']);
      final lng =
          _coord(tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef']);
      DateTime? time;
      final dt = tags['EXIF DateTimeOriginal']?.printable ??
          tags['Image DateTime']?.printable;
      if (dt != null) {
        try {
          final iso = dt.replaceFirst(':', '-').replaceFirst(':', '-');
          time = DateTime.tryParse(iso.replaceFirst(' ', 'T'));
        } catch (_) {}
      }
      if (lat == null && lng == null && time == null) return null;
      return ExifMeta(lat: lat, lng: lng, time: time);
    } catch (_) {
      return null;
    }
  }

  /// Android 10+ strips the GPS EXIF from gallery photos unless
  /// ACCESS_MEDIA_LOCATION is granted. Call once before a batch EXIF read so
  /// [readGps] actually sees coordinates. No-op on non-Android platforms.
  static Future<void> ensureLocationMetadataAccess() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.accessMediaLocation.status;
    if (!status.isGranted) await Permission.accessMediaLocation.request();
  }

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
