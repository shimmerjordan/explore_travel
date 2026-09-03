import 'package:explore_journal/ui/common/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fmtBytes', () {
    test('四档单位，KB/MB 一位小数，GB 两位', () {
      expect(fmtBytes(0), '0 B');
      expect(fmtBytes(1023), '1023 B');
      expect(fmtBytes(1024), '1.0 KB');
      expect(fmtBytes(1536), '1.5 KB');
      expect(fmtBytes(1024 * 1024), '1.0 MB');
      expect(fmtBytes(5 * 1024 * 1024 + 512 * 1024), '5.5 MB');
      expect(fmtBytes(1024 * 1024 * 1024), '1.00 GB');
      expect(fmtBytes(3 * 1024 * 1024 * 1024 + 256 * 1024 * 1024), '3.25 GB');
    });
  });

  group('fmtRelativeTime', () {
    final now = DateTime(2026, 9, 3, 12, 0, 0);

    test('一分钟内是「刚刚」', () {
      expect(fmtRelativeTime(now, now: now), '刚刚');
      expect(fmtRelativeTime(now.subtract(const Duration(seconds: 59)), now: now),
          '刚刚');
    });

    test('分钟 / 小时 / 天三档', () {
      expect(fmtRelativeTime(now.subtract(const Duration(minutes: 1)), now: now),
          '1 分钟前');
      expect(
          fmtRelativeTime(now.subtract(const Duration(minutes: 59)), now: now),
          '59 分钟前');
      expect(fmtRelativeTime(now.subtract(const Duration(hours: 1)), now: now),
          '1 小时前');
      expect(fmtRelativeTime(now.subtract(const Duration(hours: 23)), now: now),
          '23 小时前');
      expect(fmtRelativeTime(now.subtract(const Duration(days: 1)), now: now),
          '1 天前');
      expect(fmtRelativeTime(now.subtract(const Duration(days: 6)), now: now),
          '6 天前');
    });

    test('一周以上落回日期', () {
      expect(fmtRelativeTime(now.subtract(const Duration(days: 7)), now: now),
          '2026-08-27');
      expect(fmtRelativeTime(DateTime(2025, 1, 5), now: now), '2025-01-05');
    });

    test('未来时间不会变成负数', () {
      expect(fmtRelativeTime(now.add(const Duration(minutes: 5)), now: now),
          '刚刚');
    });
  });
}
