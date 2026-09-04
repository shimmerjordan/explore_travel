import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../services/ai/companion_controller.dart';
import '../common/failure.dart';
import '../common/pixel.dart';

// ─── 像素小人 ──────────────────────────────────────────────────────────────
//
// 8×8 sprite，纯 CustomPainter，不吃资源文件。配色沿用地图 chrome 的像素
// 语言：深蓝底 + 青绿脸 + 琥珀天线（呼应 M3 secondary）。

const _kFaceTeal = Color(0xFF4DB6AC);
const _kFaceDark = Color(0xFF12303A);
const _kFaceAmber = Color(0xFFF2B457);

/// 0 透明 · 1 青绿 · 2 深色 · 3 白 · 4 琥珀
const _kFaceSprite = <List<int>>[
  [0, 0, 0, 4, 4, 0, 0, 0],
  [0, 1, 1, 1, 1, 1, 1, 0],
  [1, 1, 1, 1, 1, 1, 1, 1],
  [1, 3, 3, 1, 1, 3, 3, 1],
  [1, 3, 2, 1, 1, 3, 2, 1],
  [1, 1, 1, 1, 1, 1, 1, 1],
  [0, 1, 2, 2, 2, 2, 1, 0],
  [0, 0, 1, 1, 1, 1, 0, 0],
];

class PixelFacePainter extends CustomPainter {
  /// 0..1，通话呼吸相位：脸微微变亮、天线闪烁。
  final double pulse;
  PixelFacePainter({this.pulse = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 8;
    final paint = Paint();
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        final v = _kFaceSprite[r][c];
        if (v == 0) continue;
        switch (v) {
          case 1:
            paint.color = Color.lerp(_kFaceTeal,
                const Color(0xFF80E8DC), pulse * 0.55)!;
            break;
          case 2:
            paint.color = _kFaceDark;
            break;
          case 3:
            paint.color = Colors.white;
            break;
          case 4:
            paint.color = Color.lerp(
                _kFaceAmber, const Color(0xFFFFE1A6), pulse)!;
            break;
        }
        // +0.6 让相邻格子咬合，避免亚像素缝。
        canvas.drawRect(
          Rect.fromLTWH(c * cell, r * cell, cell + 0.6, cell + 0.6),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(PixelFacePainter old) => old.pulse != pulse;
}

/// 地图左下角的 AI 头像按钮（debug 按钮上方）。
/// 通话中呼吸发光；卡片收起时有新回复亮一颗琥珀像素点。
class CompanionAvatarButton extends ConsumerStatefulWidget {
  final VoidCallback onTap;
  const CompanionAvatarButton({super.key, required this.onTap});

  @override
  ConsumerState<CompanionAvatarButton> createState() =>
      _CompanionAvatarButtonState();
}

class _CompanionAvatarButtonState extends ConsumerState<CompanionAvatarButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(companionProvider);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (c.inCall && !_breath.isAnimating && !reduceMotion) {
      _breath.repeat();
    } else if ((!c.inCall || reduceMotion) && _breath.isAnimating) {
      _breath.stop();
      _breath.value = 0;
    }
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        // 正弦呼吸 0..1（reduce motion 时定格半亮）。
        final t = c.inCall
            ? (reduceMotion
                ? 0.5
                : 0.5 - 0.5 * math.cos(_breath.value * 2 * math.pi))
            : 0.0;
        return Container(
          decoration: c.inCall
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: _kFaceTeal.withValues(alpha: 0.25 + 0.4 * t),
                      blurRadius: 6 + 12 * t,
                      spreadRadius: 1 + 2.5 * t,
                    ),
                  ],
                )
              : null,
          child: Material(
            elevation: 3,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            color: const Color(0xFF1A2733),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onTap,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Stack(
                  children: [
                    Center(
                      child: CustomPaint(
                        size: const Size(28, 28),
                        painter: PixelFacePainter(pulse: t),
                      ),
                    ),
                    if (c.unread > 0)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: Container(
                          width: 8,
                          height: 8,
                          color: _kFaceAmber, // 像素点，不圆角
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── 侧吸卡片 ──────────────────────────────────────────────────────────────

/// 从左缘滑入的悬浮对话卡片。地图保持可见（PRODUCT.md：地图是主角）。
class CompanionCard extends ConsumerStatefulWidget {
  final VoidCallback onClosed;
  const CompanionCard({super.key, required this.onClosed});

  @override
  ConsumerState<CompanionCard> createState() => CompanionCardState();
}

class CompanionCardState extends ConsumerState<CompanionCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  final _input = TextEditingController();
  final _focus = FocusNode();
  XFile? _pendingImage;

  bool _entered = false;
  int _tab = 0; // 0 对话 · 1 历史

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entered) return;
    _entered = true;
    if (MediaQuery.of(context).disableAnimations) {
      _slide.value = 1; // 尊重系统“移除动画”
    } else {
      _slide.forward();
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 最小化（带滑出动画）。通话不受影响，头像继续呼吸。
  Future<void> close() async {
    _focus.unfocus();
    try {
      await _slide.reverse();
    } catch (_) {}
    widget.onClosed();
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍一张'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    try {
      final x = await ImagePicker()
          .pickImage(source: source, maxWidth: 1440, imageQuality: 82);
      if (x != null && mounted) setState(() => _pendingImage = x);
    } catch (e, st) {
      // 重试重新走「拍一张 / 从相册选」这张选择单，和用户自己再点一次一样。
      if (mounted) {
        showFailure(context,
            action: '选图', error: e, stack: st, onRetry: _pickImage);
      }
    }
  }

  void _send() {
    final c = ref.read(companionProvider);
    final text = _input.text;
    final img = _pendingImage?.path;
    if (text.trim().isEmpty && img == null) return;
    _input.clear();
    setState(() => _pendingImage = null);
    c.sendText(text, imagePath: img);
  }

  Future<void> _toggleCall() async {
    final c = ref.read(companionProvider);
    if (c.inCall) {
      await c.hangUp();
      return;
    }
    final err = await c.startCall();
    if (err != null) _toast(err);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(companionProvider);
    final cs = Theme.of(context).colorScheme;
    return SlideTransition(
      position: Tween(begin: const Offset(-1.05, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: _slide, curve: Curves.easeOutQuart)),
      child: FadeTransition(
        opacity: _slide,
        child: DecoratedBox(
          // 悬浮在花花绿绿的地图上，需要一层影子把卡片“抬”起来。
          decoration: BoxDecoration(boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: .30),
                blurRadius: 18,
                offset: const Offset(2, 6)),
          ]),
          child: PixelPanel(
            color: cs.surface,
            borderColor: cs.outlineVariant.withValues(alpha: .55),
            clipChild: true,
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                // 卡片向左越界 6px 藏掉贴边侧的阶梯角，这里补回内容内距。
                padding: const EdgeInsets.only(left: 6),
                child: Column(
                  children: [
                    _header(c, cs),
                    _tabRow(c, cs),
                    Divider(
                        height: 1,
                        color: cs.outlineVariant.withValues(alpha: .4)),
                    Expanded(
                        child: _tab == 0
                            ? _chatList(c, cs)
                            : _historyList(c, cs)),
                    // 通话条跨 Tab 常显（通话状态不能因为翻历史而不可见）；
                    // 输入行只属于对话 Tab。
                    if (c.inCall)
                      _callStrip(c, cs)
                    else if (_tab == 0)
                      _inputBar(c, cs),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(CompanionController c, ColorScheme cs) {
    final phaseLabel = switch (c.callPhase) {
      CallPhase.listening => '通话中 · 在听',
      CallPhase.thinking => '通话中 · 思考',
      CallPhase.speaking => '通话中 · 说话',
      CallPhase.off => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(children: [
        CustomPaint(
            size: const Size(24, 24),
            painter: PixelFacePainter(pulse: c.inCall ? 0.5 : 0)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('AI 旅伴',
                  style:
                      TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              if (phaseLabel.isNotEmpty)
                Text(phaseLabel,
                    style: TextStyle(fontSize: 10.5, color: cs.primary)),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: c.inCall ? '挂断' : '语音通话',
          onPressed: _toggleCall,
          icon: Icon(
            c.inCall ? Icons.call_end_rounded : Icons.call_rounded,
            size: 20,
            color: c.inCall ? cs.error : cs.primary,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'AI 服务设置',
          onPressed: () => context.push('/settings/ai'),
          icon: Icon(Icons.settings_rounded,
              size: 20, color: cs.onSurfaceVariant),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '收起（通话继续）',
          onPressed: close,
          icon: Icon(Icons.first_page_rounded,
              size: 20, color: cs.onSurfaceVariant),
        ),
      ]),
    );
  }

  Widget _tabRow(CompanionController c, ColorScheme cs) {
    Widget tab(int i, String label) {
      final sel = _tab == i;
      return InkWell(
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            // 像素语言：选中态 = 2px 硬边下划线，不用圆角胶囊。
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: sel ? cs.primary : Colors.transparent,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              color: sel ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Row(children: [
      const SizedBox(width: 6),
      tab(0, '对话'),
      tab(1, '历史${c.sessions.isEmpty ? '' : ' ${c.sessions.length}'}'),
    ]);
  }

  // ─── 历史 Tab：会话列表 + 新对话 / 删除 / 清空 ───

  Widget _historyList(CompanionController c, ColorScheme cs) {
    final blocked = c.busy || c.inCall;
    void guard(VoidCallback action) {
      if (blocked) {
        _toast(c.inCall ? '通话中不能整理历史，先挂断' : '回复生成中，稍等一下');
        return;
      }
      action();
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Row(children: [
          TextButton.icon(
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.add_comment_outlined, size: 16),
            label: const Text('新对话', style: TextStyle(fontSize: 12)),
            onPressed: () => guard(() async {
              await c.newSession();
              if (mounted) setState(() => _tab = 0);
            }),
          ),
          const Spacer(),
          if (c.sessions.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: cs.error),
              icon: const Icon(Icons.delete_sweep_outlined, size: 16),
              label: const Text('清空', style: TextStyle(fontSize: 12)),
              onPressed: () => guard(() => _confirmClearAll(c)),
            ),
        ]),
      ),
      Expanded(
        child: c.sessions.isEmpty
            ? Center(
                child: Text('还没有历史对话',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: c.sessions.length,
                itemBuilder: (context, i) {
                  final s = c.sessions[c.sessions.length - 1 - i];
                  final active = s.id == c.activeSessionId;
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    selected: active,
                    selectedTileColor:
                        cs.primaryContainer.withValues(alpha: .25),
                    leading: Icon(
                      active
                          ? Icons.chat_bubble_rounded
                          : Icons.chat_bubble_outline_rounded,
                      size: 18,
                      color: active ? cs.primary : cs.onSurfaceVariant,
                    ),
                    title: Text(
                      s.title.isEmpty ? '（还没聊出内容）' : s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '${DateFormat('MM-dd HH:mm').format(s.createdAt)}'
                      ' · ${s.messages.length} 条'
                      '${active ? ' · 当前' : ''}',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    trailing: IconButton(
                      tooltip: '删除这段对话',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close_rounded,
                          size: 16, color: cs.onSurfaceVariant),
                      onPressed: () =>
                          guard(() => _confirmDeleteSession(c, s)),
                    ),
                    onTap: () => guard(() async {
                      await c.switchSession(s.id);
                      if (mounted) setState(() => _tab = 0);
                    }),
                  );
                },
              ),
      ),
    ]);
  }

  Future<void> _confirmDeleteSession(
      CompanionController c, CompanionSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除这段对话？'),
        content: Text(
            '「${s.title.isEmpty ? '（还没聊出内容）' : s.title}」的 ${s.messages.length} 条消息将被删除，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await c.deleteSession(s.id);
  }

  Future<void> _confirmClearAll(CompanionController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('清空全部历史？'),
        content: Text('共 ${c.sessions.length} 段对话将被删除，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) await c.clearHistory();
  }

  Widget _chatList(CompanionController c, ColorScheme cs) {
    if (c.messages.isEmpty) return _emptyState(cs);
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      itemCount: c.messages.length,
      itemBuilder: (context, i) {
        final m = c.messages[c.messages.length - 1 - i];
        return _Bubble(m: m);
      },
    );
  }

  Widget _emptyState(ColorScheme cs) {
    final s = ref.watch(settingsProvider);
    final noKey = (s.aiApiKey ?? '').isEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
                size: const Size(52, 52), painter: PixelFacePainter()),
            const SizedBox(height: 14),
            Text('嗨，我是小岚！',
                style: PixelText.headline.copyWith(color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              '路线怎么走、这是什么建筑、附近吃什么——\n打字、拍照，或点右上角 📞 直接开聊。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: cs.onSurfaceVariant),
            ),
            if (noKey) ...[
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/settings/ai'),
                icon: const Icon(Icons.settings_rounded, size: 16),
                label: const Text('先去配置 AI 服务'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 通话条：相位指示 + 提示语 + 打断/挂断。
  Widget _callStrip(CompanionController c, ColorScheme cs) {
    final (label, icon, color) = switch (c.callPhase) {
      CallPhase.listening => ('在听你说', Icons.mic_rounded, cs.primary),
      CallPhase.thinking => ('想想…', Icons.more_horiz_rounded, cs.tertiary),
      CallPhase.speaking =>
        ('说话中', Icons.graphic_eq_rounded, cs.secondary),
      CallPhase.off => ('', Icons.mic_off_rounded, cs.onSurfaceVariant),
    };
    return Container(
      color: cs.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(children: [
        _PhaseBeacon(phase: c.callPhase, color: color, icon: icon),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: color)),
              if (c.callHint.isNotEmpty)
                Text(c.callHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        if (c.callPhase == CallPhase.speaking ||
            c.callPhase == CallPhase.thinking)
          IconButton(
            tooltip: '打断',
            visualDensity: VisualDensity.compact,
            onPressed: c.interrupt,
            icon: Icon(Icons.front_hand_rounded,
                size: 20, color: cs.onSurfaceVariant),
          ),
        IconButton.filled(
          tooltip: '挂断',
          style: IconButton.styleFrom(
              backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: c.hangUp,
          icon: const Icon(Icons.call_end_rounded, size: 20),
        ),
      ]),
    );
  }

  Widget _inputBar(CompanionController c, ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerLow,
      padding: EdgeInsets.fromLTRB(
          6, 6, 8, 6 + MediaQuery.of(context).padding.bottom * 0),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_pendingImage != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(_pendingImage!.path),
                      width: 64, height: 64, fit: BoxFit.cover),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => setState(() => _pendingImage = null),
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.all(2),
                      child: const Icon(Icons.close,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconButton(
            tooltip: '发图片',
            visualDensity: VisualDensity.compact,
            onPressed: c.busy ? null : _pickImage,
            icon: Icon(Icons.add_photo_alternate_outlined,
                size: 22, color: cs.onSurfaceVariant),
          ),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '和旅伴聊聊…',
                hintStyle:
                    TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                isDense: true,
                filled: true,
                fillColor: cs.surface,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          c.busy
              ? IconButton.filledTonal(
                  tooltip: '停止生成',
                  onPressed: c.stopStreaming,
                  icon: const Icon(Icons.stop_rounded, size: 20),
                )
              : IconButton.filled(
                  tooltip: '发送',
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                ),
        ]),
      ]),
    );
  }
}

// ─── 气泡 ─────────────────────────────────────────────────────────────────

class _Bubble extends StatelessWidget {
  final CompanionMessage m;
  const _Bubble({required this.m});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = m.role == 'user';
    final bg = m.error
        ? cs.errorContainer
        : isUser
            ? cs.primaryContainer
            : cs.surfaceContainerHigh;
    final fg = m.error
        ? cs.onErrorContainer
        : isUser
            ? cs.onPrimaryContainer
            : cs.onSurface;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(10),
      topRight: const Radius.circular(10),
      bottomLeft: Radius.circular(isUser ? 10 : 2),
      bottomRight: Radius.circular(isUser ? 2 : 10),
    );
    final text = m.streaming && m.text.isEmpty ? '…' : m.text;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: m.text));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('已复制'), duration: Duration(milliseconds: 700)));
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          constraints: const BoxConstraints(maxWidth: 250),
          decoration: BoxDecoration(color: bg, borderRadius: radius),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.imagePath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(File(m.imagePath!),
                        width: 150,
                        errorBuilder: (_, __, ___) => Container(
                              width: 150,
                              height: 60,
                              color: cs.surfaceContainerHighest,
                              alignment: Alignment.center,
                              child: Text('图片已清理',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant)),
                            )),
                  ),
                ),
              if (isUser || m.error)
                Text(text,
                    style:
                        TextStyle(fontSize: 13.5, height: 1.45, color: fg))
              else
                MarkdownBody(
                  data: m.streaming ? '$text ▌' : text,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                    p: TextStyle(fontSize: 13.5, height: 1.45, color: fg),
                    code: TextStyle(
                        fontSize: 12.5,
                        fontFamily: 'monospace',
                        backgroundColor:
                            cs.surfaceContainerHighest.withValues(alpha: .6)),
                    listBullet:
                        TextStyle(fontSize: 13.5, height: 1.45, color: fg),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 通话相位指示灯 ────────────────────────────────────────────────────────

/// 听 = 呼吸圆点；想 = 三点跳动；说 = 四柱均衡器。像素感：全部方块。
class _PhaseBeacon extends StatefulWidget {
  final CallPhase phase;
  final Color color;
  final IconData icon;
  const _PhaseBeacon(
      {required this.phase, required this.color, required this.icon});

  @override
  State<_PhaseBeacon> createState() => _PhaseBeaconState();
}

class _PhaseBeaconState extends State<_PhaseBeacon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      // Stop the ticker too — the early return alone left it running.
      if (_ctrl.isAnimating) _ctrl.stop();
      return Icon(widget.icon, size: 22, color: widget.color);
    }
    if (!_ctrl.isAnimating) _ctrl.repeat();
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => CustomPaint(
        size: const Size(26, 26),
        painter: _BeaconPainter(
            phase: widget.phase, color: widget.color, t: _ctrl.value),
      ),
    );
  }
}

class _BeaconPainter extends CustomPainter {
  final CallPhase phase;
  final Color color;
  final double t;
  _BeaconPainter({required this.phase, required this.color, required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final w = size.width;
    switch (phase) {
      case CallPhase.listening:
        // 呼吸方点：中心方块 + 外圈随呼吸展开的 4 个角标。
        final s = 8 + 3 * math.sin(t * 2 * math.pi);
        canvas.drawRect(
            Rect.fromCenter(
                center: Offset(w / 2, w / 2), width: s, height: s),
            p);
        final a = p.color.withValues(alpha: .45);
        final q = Paint()..color = a;
        final off = 8 + 2.5 * math.sin(t * 2 * math.pi);
        for (final d in const [(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
          canvas.drawRect(
              Rect.fromCenter(
                  center: Offset(w / 2 + d.$1 * off, w / 2 + d.$2 * off),
                  width: 3,
                  height: 3),
              q);
        }
        break;
      case CallPhase.thinking:
        for (var i = 0; i < 3; i++) {
          final ph = (t * 2 * math.pi) - i * 0.9;
          final y = w / 2 - 3.5 * math.max(0, math.sin(ph));
          canvas.drawRect(
              Rect.fromCenter(
                  center: Offset(6.0 + i * 7, y + 3), width: 4, height: 4),
              p);
        }
        break;
      case CallPhase.speaking:
        for (var i = 0; i < 4; i++) {
          final ph = t * 2 * math.pi + i * 1.7;
          final h = 6 + 12 * (0.5 + 0.5 * math.sin(ph)).abs();
          canvas.drawRect(
              Rect.fromCenter(
                  center: Offset(4.5 + i * 6, w / 2), width: 3.6, height: h),
              p);
        }
        break;
      case CallPhase.off:
        break;
    }
  }

  @override
  bool shouldRepaint(_BeaconPainter old) =>
      old.t != t || old.phase != phase || old.color != color;
}
