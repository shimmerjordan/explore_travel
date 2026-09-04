/// 空状态：**教用户怎么让它不空**，不是写一句"暂无数据"。
///
/// 全局第一个把这件事做对的是 3D 地球页：「还没有任何足迹。开始记录后，走过
/// 的地方会在这里点亮地球。」——一句现状 + 一句「接下来怎么办」。这个组件把
/// 那个模板固化下来，顺带统一像素精灵、间距与可选的行动按钮。
///
/// 加载态请用 [LoadingState]：内容区中央转圈是 product register 明确反对的，
/// 但比起「一片空白让人以为坏了」它仍是必要的，所以这里给一个带说明文字的
/// 统一版本。
library;

import 'package:flutter/material.dart';

import 'pixel.dart';

/// 空状态。[title] 说现状，[hint] 说下一步该做什么（可选但强烈建议给）。
/// [sprite] 传 [PixelSprites] 里的一张；不传就只有文字。
class EmptyState extends StatelessWidget {
  final String title;
  final String? hint;
  final List<String>? sprite;

  /// 行动按钮。空状态最好能就地引导，而不是让用户自己去找入口。
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 页面级空状态默认居中铺满；嵌在卡片/分区里时传 false 走紧凑版。
  final bool expand;

  const EmptyState({
    super.key,
    required this.title,
    this.hint,
    this.sprite,
    this.actionLabel,
    this.onAction,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sprite != null) ...[
          PixelSprite(
            rows: sprite!,
            // 空状态的精灵是氛围，不是主角：压到次要文字的亮度，别抢标题。
            color: cs.onSurfaceVariant.withValues(alpha: 0.55),
            accent: cs.primary.withValues(alpha: 0.7),
            cell: 4,
          ),
          const SizedBox(height: 18),
        ],
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: cs.onSurface),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            // 空状态的引导语不该拉成通栏长行。
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              hint!,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant, height: 1.5),
            ),
          ),
        ],
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 20),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ],
    );
    final padded = Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: expand ? 40 : 24),
      child: content,
    );
    return expand ? Center(child: padded) : padded;
  }
}

/// 加载态。[label] 说清在等什么——「统计中…」比一个孤零零的转圈有用得多。
class LoadingState extends StatelessWidget {
  final String? label;
  final bool expand;
  const LoadingState({super.key, this.label, this.expand = true});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        if (label != null) ...[
          const SizedBox(height: 14),
          Text(label!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ],
    );
    final padded = Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: expand ? 40 : 24),
      child: content,
    );
    return expand ? Center(child: padded) : padded;
  }
}
