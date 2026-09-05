/// 总结卡的预览与分享。
///
/// 先让用户看到要发出去的那张图，再决定发不发——这也顺带避开了离屏渲染的坑：
/// 抓的是屏上真实布局过的 `RepaintBoundary`，与回放页导出视频同一套（那条路
/// 已经真机验证过）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/stats/summary_card_data.dart';
import '../common/failure.dart';
import 'summary_card.dart';

/// 打开总结卡预览。[data] 由调用方按自己的范围装配好。
Future<void> openSummaryCard(BuildContext context, SummaryCardData data) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => SummaryCardScreen(data: data),
  ));
}

class SummaryCardScreen extends StatefulWidget {
  final SummaryCardData data;
  const SummaryCardScreen({super.key, required this.data});

  @override
  State<SummaryCardScreen> createState() => _SummaryCardScreenState();
}

class _SummaryCardScreenState extends State<SummaryCardScreen> {
  final _cardKey = GlobalKey();
  bool _busy = false;

  /// 抓成 1080 宽的 PNG。逻辑宽度固定（[kSummaryCardSize]），所以不同 DPI 的
  /// 设备导出的图是一样大的。
  Future<File?> _render() async {
    final boundary =
        _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final pixelRatio = (1080 / boundary.size.width).clamp(1.0, 4.0);
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final out = File(p.join(dir.path, 'exports', 'summary_$stamp.png'));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      return out;
    } finally {
      image.dispose();
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _render();
      if (file == null) {
        if (mounted) {
          showFailure(context, action: '生成图片', onRetry: _share);
        }
        return;
      }
      await Share.shareXFiles([XFile(file.path)],
          subject: '${widget.data.range.title} · Explore Journal');
    } catch (e, st) {
      if (mounted) {
        showFailure(context, action: '分享', error: e, stack: st, onRetry: _share);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('总结卡')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              // 抓图边界只包卡片本身——按钮、脚手架都不该进图里。
              RepaintBoundary(
                key: _cardKey,
                child: SummaryCard(data: widget.data),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _share,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(_busy ? '生成中…' : '分享这张图'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
