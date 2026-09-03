import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/prefs.dart';
import '../security/http_guard.dart';

/// Custom URL scheme we hand back from [GithubBackend] when an entry is
/// marked private. The display "URL" stored in the journal looks like:
///
///   `gh-private://<owner>/<repo>@<branch>/<path>`
///
/// Nothing else in the app knows what to do with this scheme — [PrivateImage]
/// (below) detects it, looks up the PAT in settings, and fetches the raw
/// bytes with `Authorization: Bearer <pat>`. Bytes are kept in an in-memory
/// LRU so re-opening a journal doesn't re-download.
class PrivateImageRef {
  final String owner;
  final String repo;
  final String branch;
  final String path;
  const PrivateImageRef({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.path,
  });

  String toCustomUrl() => 'gh-private://$owner/$repo@$branch/$path';

  static PrivateImageRef? tryParse(String url) {
    if (!url.startsWith('gh-private://')) return null;
    final rest = url.substring('gh-private://'.length);
    final firstSlash = rest.indexOf('/');
    if (firstSlash < 0) return null;
    final owner = rest.substring(0, firstSlash);
    final after = rest.substring(firstSlash + 1);
    final atIdx = after.indexOf('@');
    if (atIdx < 0) return null;
    final repo = after.substring(0, atIdx);
    final afterAt = after.substring(atIdx + 1);
    final pathSlash = afterAt.indexOf('/');
    if (pathSlash < 0) return null;
    final branch = afterAt.substring(0, pathSlash);
    final path = afterAt.substring(pathSlash + 1);
    return PrivateImageRef(
        owner: owner, repo: repo, branch: branch, path: path);
  }
}

class _Cache {
  static final _bytes = <String, Uint8List>{};
  static const _max = 64;
  static Uint8List? get(String k) => _bytes[k];
  static void put(String k, Uint8List v) {
    _bytes[k] = v;
    if (_bytes.length > _max) {
      _bytes.remove(_bytes.keys.first);
    }
  }
}

/// Drop-in `Image` replacement that supports both regular URLs and the
/// custom `gh-private://` scheme. The PAT comes from app settings — pass it
/// in so we don't have to wire Riverpod through every render path.
class PrivateAwareImage extends StatefulWidget {
  final String url;
  final AppSettings settings;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function(BuildContext)? errorBuilder;

  const PrivateAwareImage({
    super.key,
    required this.url,
    required this.settings,
    this.fit = BoxFit.contain,
    this.width,
    this.height,
    this.errorBuilder,
  });

  @override
  State<PrivateAwareImage> createState() => _PrivateAwareImageState();
}

class _PrivateAwareImageState extends State<PrivateAwareImage> {
  /// 拿不到布局宽度时（全屏查看器、无约束的富文本内嵌）的解码宽度上限，
  /// 物理像素：手机屏宽级别的清晰度，又不会把一张几千万像素的原图整张解进
  /// ImageCache —— 那正是相册缩略图把迷雾瓦片挤出缓存的老问题（对照
  /// map_screen 里手账气泡的 cacheWidth: 120）。
  static const int kFallbackCacheWidth = 1080;

  Uint8List? _bytes;
  Object? _err;

  /// 按屏幕上真正要画的像素数解码：逻辑宽 × devicePixelRatio。宽度未知就用
  /// [kFallbackCacheWidth]；ResizeImage 默认不放大，小图不受影响。
  static int _cacheWidthFor(BuildContext context, double? logicalWidth) {
    if (logicalWidth == null || !logicalWidth.isFinite || logicalWidth <= 0) {
      return kFallbackCacheWidth;
    }
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    return (logicalWidth * dpr).ceil();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PrivateAwareImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    final ref = PrivateImageRef.tryParse(widget.url);
    if (ref == null) return; // regular URL — handled by Image.network below.
    final cached = _Cache.get(widget.url);
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    final pat = widget.settings.githubPrivatePat;
    if (pat == null || pat.isEmpty) {
      setState(() => _err = StateError('未配置私有仓 PAT'));
      return;
    }
    final raw =
        'https://raw.githubusercontent.com/${ref.owner}/${ref.repo}/${ref.branch}/${ref.path}';
    try {
      final dio = guardedDio();
      final resp = await dio.get<List<int>>(
        raw,
        options: Options(
          headers: {
            'Authorization': 'Bearer $pat',
            'Accept': 'application/vnd.github.raw',
          },
          responseType: ResponseType.bytes,
          followRedirects: true,
        ),
      );
      final bytes = Uint8List.fromList(resp.data ?? const []);
      _Cache.put(widget.url, bytes);
      if (mounted) setState(() => _bytes = bytes);
    } catch (e, st) {
      debugPrint('[PrivateImage] load failed for ${widget.url}: $e\n$st');
      if (mounted) setState(() => _err = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = PrivateImageRef.tryParse(widget.url);
    if (ref == null) {
      // Regular http(s) — let Flutter handle.
      return Image.network(
        widget.url,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        errorBuilder: (ctx, _, __) =>
            widget.errorBuilder?.call(ctx) ?? const SizedBox.shrink(),
      );
    }
    if (_err != null) {
      return widget.errorBuilder?.call(context) ?? const SizedBox.shrink();
    }
    if (_bytes == null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    // No explicit width (rich-text embed, full-screen viewer) → take the width
    // the parent actually gives us; unbounded → the fallback cap.
    return LayoutBuilder(
      builder: (ctx, constraints) => Image.memory(
        _bytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: _cacheWidthFor(
            ctx,
            widget.width ??
                (constraints.hasBoundedWidth ? constraints.maxWidth : null)),
        errorBuilder: (ctx, _, __) =>
            widget.errorBuilder?.call(ctx) ?? const SizedBox.shrink(),
      ),
    );
  }
}
