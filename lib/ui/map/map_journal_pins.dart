// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 手账在地图上的呈现：列表卡、缩略图、图钉。
part of 'map_screen.dart';

class _JournalCard extends StatelessWidget {
  final db_t.JournalEntry entry;
  final double distanceMeters;
  final VoidCallback onTap;
  const _JournalCard({
    required this.entry,
    required this.distanceMeters,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final paths =
        entry.mediaPaths.split('\n').where((p) => p.isNotEmpty).toList();
    final preview = _previewText(entry.richContent);
    final distLabel = distanceMeters < 1000
        ? '${distanceMeters.toStringAsFixed(0)} m'
        : '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (paths.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: _Thumb(path: paths.first),
                  ),
                )
              else
                Container(
                  width: 72,
                  height: 72,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.15),
                  child: Center(
                    child: PixelSprite(
                      rows: PixelSprites.book,
                      color: Theme.of(context).colorScheme.primary,
                      cell: 4,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          color: const Color(0xFF26A69A).withValues(alpha: 0.2),
                          child: Text(distLabel,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF26A69A),
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (preview.isNotEmpty)
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      fmtRelativeTime(entry.time),
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片里只有一两行位置，换行压成空格。
  static String _previewText(String richContent) =>
      quillToPreview(richContent).replaceAll('\n', ' ').trim();
}

class _Thumb extends StatelessWidget {
  final String path;
  const _Thumb({required this.path});
  @override
  Widget build(BuildContext context) {
    final lower = path.toLowerCase();
    final isVideo = lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv');
    if (isVideo) {
      return Container(
        color: Colors.black26,
        alignment: Alignment.center,
        child: const Icon(Icons.play_circle, size: 28),
      );
    }
    if (path.startsWith('http')) {
      return Image.network(path,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
    }
    if (kIsWeb) {
      // No filesystem access on web — show generic icon.
      return Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: const Icon(Icons.image_outlined, size: 28),
      );
    }
    return NativeFileImage(path: path);
  }
}

/// Map pin for a journal entry: a small thumbnail (first media image if any,
/// otherwise an icon) on top of a teardrop tail. Tapped via the enclosing
/// GestureDetector to open the read-only viewer.
class _JournalPin extends StatelessWidget {
  final db_t.JournalEntry entry;
  const _JournalPin({required this.entry});

  @override
  Widget build(BuildContext context) {
    final firstImage =
        entry.mediaPaths.split('\n').where((p) => p.isNotEmpty).where((p) {
      final l = p.toLowerCase();
      return !(l.endsWith(".mp4") || l.endsWith(".mov") || l.endsWith(".mkv"));
    }).firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35), blurRadius: 4),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: firstImage == null
              ? Container(
                  color: const Color(0xFFFF8A65),
                  alignment: Alignment.center,
                  child: const Icon(Icons.menu_book_rounded,
                      color: Colors.white, size: 20),
                )
              : Image.file(
                  File(firstImage),
                  fit: BoxFit.cover,
                  // A 40 px bubble; without this the full-resolution photo
                  // was decoded into the ImageCache (and evicted fog tiles).
                  cacheWidth: 120,
                  cacheHeight: 120,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFFFF8A65),
                    alignment: Alignment.center,
                    child: const Icon(Icons.menu_book_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
        ),
        // Tail
        CustomPaint(
          size: const Size(12, 8),
          painter: _PinTailPainter(),
        ),
      ],
    );
  }
}

class _PinTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
