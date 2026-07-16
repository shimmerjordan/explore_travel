import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../models/models.dart';
import '../../services/ai/ai_service.dart';
import '../widgets/responsive_content.dart';

/// 设置页。信息架构（按使用频率）：
///   外观 → 记录与迷雾 → 地图 → 服务配置 → 更多
/// 低频且成组的配置（地图 Key、AI 服务）折叠进底部抽屉，
/// 页面本身只保留"一眼可读的当前状态 + 常用开关"。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);

    final keyCount = [s.customOsmTileUrl, s.amapApiKey, s.googleMapKey]
        .where((v) => (v ?? '').isNotEmpty)
        .length;

    return Scaffold(
      body: ResponsiveContent(
          child: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('设置',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              const _SectionHeader('外观'),
              _SegmentedTile<String>(
                icon: Icons.palette_outlined,
                title: '主题',
                segments: const [
                  ButtonSegment(
                      value: 'light',
                      icon: Icon(Icons.wb_sunny_outlined, size: 15),
                      label: Text('轻快', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                      value: 'dark',
                      icon: Icon(Icons.nightlight_outlined, size: 15),
                      label: Text('暗黑', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                      value: 'system',
                      icon: Icon(Icons.hdr_auto_outlined, size: 15),
                      label: Text('系统', style: TextStyle(fontSize: 11))),
                ],
                selected: s.themePref,
                onChanged: (v) => n.update((p) => p.copyWith(themePref: v)),
              ),
              const _SectionHeader('记录与迷雾'),
              _SegmentedTile<RecordingMode>(
                icon: Icons.speed_rounded,
                title: '记录模式',
                segments: RecordingMode.values
                    .map((m) => ButtonSegment(
                        value: m,
                        label: Text(m.label,
                            style: const TextStyle(fontSize: 11))))
                    .toList(),
                selected: s.recordingMode,
                onChanged: (v) =>
                    n.update((p) => p.copyWith(recordingMode: v)),
              ),
              ListTile(
                leading: const Icon(Icons.palette_rounded),
                title: const Text('迷雾颜色'),
                trailing: _ColorDot(color: Color(s.fogColor)),
                onTap: () => _pickColor(context, s.fogColor,
                    (c) => n.update((p) => p.copyWith(fogColor: c))),
              ),
              _SliderTile(
                icon: Icons.blur_on_rounded,
                title: '迷雾浓度',
                valueLabel: '${(s.fogOpacity * 100).round()}%',
                value: s.fogOpacity,
                min: 0.3,
                max: 1.0,
                divisions: 20,
                onChanged: (v) => n.update((p) => p.copyWith(fogOpacity: v)),
              ),
              _SliderTile(
                icon: Icons.timeline_rounded,
                title: '轨迹粗细',
                subtitle: '只影响之后记录的轨迹',
                valueLabel: '${s.trailWidth.toStringAsFixed(0)} m',
                value: s.trailWidth,
                min: 2,
                max: 60,
                divisions: 58,
                onChanged: (v) => n.update((p) => p.copyWith(trailWidth: v)),
              ),
              _SliderTile(
                icon: Icons.brush_rounded,
                title: '擦除 / 涂抹半径',
                subtitle: '地图上手动补涂、擦除迷雾的笔刷',
                valueLabel: '${s.fogPenRadius.toStringAsFixed(0)} m',
                value: s.fogPenRadius,
                min: 5,
                max: 200,
                divisions: 39,
                onChanged: (v) =>
                    n.update((p) => p.copyWith(fogPenRadius: v)),
              ),
              const _SectionHeader('地图'),
              _SegmentedTile<MapProvider>(
                icon: Icons.map_rounded,
                // 短标题：与右侧三段选择器同行时"地图提供商"会被挤成两行。
                title: '提供商',
                segments: const [
                  ButtonSegment(
                      value: MapProvider.osm,
                      label: Text('OSM', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                      value: MapProvider.amap,
                      label: Text('高德', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                      value: MapProvider.google,
                      label: Text('Google', style: TextStyle(fontSize: 11))),
                ],
                selected: s.mapProvider,
                onChanged: (v) =>
                    n.update((p) => p.copyWith(mapProvider: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.screen_rotation_rounded),
                title: const Text('允许地图旋转'),
                subtitle: const Text('开启后可双指旋转，指南针可一键回正北'),
                value: s.allowMapRotation,
                onChanged: (v) =>
                    n.update((p) => p.copyWith(allowMapRotation: v)),
              ),
              ListTile(
                leading: const Icon(Icons.key_rounded),
                title: const Text('瓦片源与 API Key'),
                subtitle: Text(keyCount == 0
                    ? '可选 · 不填也能正常用地图'
                    : '已配置 $keyCount 项'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showSheet(context, const _MapKeysSheet()),
              ),
              const _SectionHeader('AI'),
              ListTile(
                leading: const Icon(Icons.smart_toy_rounded),
                title: const Text('AI 服务'),
                subtitle: Text((s.aiBaseUrl ?? '').isEmpty
                    ? '未配置 · 用于旅行规划与歌单'
                    : (s.aiModel.isEmpty ? s.aiBaseUrl! : s.aiModel)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showSheet(context, const _AiSheet()),
              ),
              const _SectionHeader('更多'),
              ListTile(
                leading: const Icon(Icons.cloud_sync_rounded),
                title: const Text('导出与导入'),
                subtitle: const Text('本地 / WebDAV / OneDrive / FOW 兼容'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/backup'),
              ),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('后台记录设置'),
                subtitle: const Text('定位权限 / 电池豁免 — 排查"后台不记录"'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/permissions'),
              ),
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: const Text('组队配置'),
                subtitle: const Text('传输方式 / 群组 ID / 昵称 / 共享口令'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/group/setup'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('关于 Explore Journal'),
                subtitle: const Text('版本号 / 仓库 / 文档 / 许可证'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/about'),
              ),
              const SizedBox(height: 60),
            ]),
          ),
        ],
      )),
    );
  }

  /// 统一的设置抽屉：M3 底部弹层，避开输入法，可滚动。
  static Future<void> _showSheet(BuildContext context, Widget child) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: child,
      ),
    );
  }

  void _pickColor(
      BuildContext context, int current, Function(int) onPick) {
    final palette = [
      0xFF101820, 0xFF1A237E, 0xFF263238, 0xFF4A148C, 0xFF1B5E20,
      0xFFB71C1C, 0xFFE65100, 0xFF3E2723, 0xFF000000, 0xFF37474F,
    ];
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('选择迷雾颜色'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: palette
              .map((c) => GestureDetector(
                    onTap: () {
                      onPick(c);
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: c == current
                            ? Border.all(width: 3, color: Colors.white)
                            : null,
                      ),
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5)),
      );
}

/// 分段选择行：控件本身就显示当前值，不再放重复的文字副标题。
class _SegmentedTile<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  const _SegmentedTile({
    required this.icon,
    required this.title,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: SegmentedButton<T>(
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: segments,
          selected: {selected},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
      );
}

/// 滑杆行：标题与当前值同一行（值用主色徽标），滑杆紧贴其下 ——
/// 三个滑杆共用同一套版式，形成节奏。
class _SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  const _SliderTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: cs.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: TextStyle(
                              fontSize: 11.5, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(valueLabel,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSecondaryContainer)),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  const _ColorDot({required this.color});
  @override
  Widget build(BuildContext context) => Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .outline
                  .withValues(alpha: 0.3),
              width: 1.5),
        ),
      );
}

/// 抽屉里的即存文本框：输入即写入设置（与备份页同模式），无需保存按钮。
class _SheetField extends StatefulWidget {
  final IconData icon;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool obscure;
  const _SheetField(this.icon, this.label, this.value, this.onChanged,
      {this.hint, this.obscure = false});
  @override
  State<_SheetField> createState() => _SheetFieldState();
}

class _SheetFieldState extends State<_SheetField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value);
  late bool _obscured = widget.obscure;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: TextField(
        controller: _ctrl,
        obscureText: _obscured,
        decoration: InputDecoration(
          prefixIcon: Icon(widget.icon, size: 18),
          labelText: widget.label,
          hintText: widget.hint,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: widget.obscure
              ? IconButton(
                  icon: Icon(
                      _obscured
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 18),
                  onPressed: () => setState(() => _obscured = !_obscured),
                )
              : null,
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  final String title;
  final String? note;
  const _SheetTitle(this.title, {this.note});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(note!,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

/// 瓦片源 / API Key 抽屉 —— 原设置页的说明卡 + 三个字段合并至此。
class _MapKeysSheet extends ConsumerWidget {
  const _MapKeysSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetTitle(
            '瓦片源与 API Key',
            note: '高德 / Google 的栅格瓦片是公共直连，不填 Key 也能正常显示地图。'
                'Key 只用于离线缓存配额、地名搜索与 POI 检索。\n'
                'tile.openstreetmap.org 国内访问常超时，建议用高德或填一个国内可达的 OSM 镜像。',
          ),
          _SheetField(
            Icons.link_rounded,
            'OSM 瓦片自定义 URL',
            s.customOsmTileUrl ?? '',
            (v) => n.update((p) => p.copyWith(customOsmTileUrl: v)),
            hint: '留空用默认；占位符 {z}/{x}/{y}',
          ),
          _SheetField(
            Icons.key_rounded,
            '高德 API Key',
            s.amapApiKey ?? '',
            (v) => n.update((p) => p.copyWith(amapApiKey: v)),
            hint: '可选，用于地名搜索 / POI',
            obscure: true,
          ),
          _SheetField(
            Icons.key_rounded,
            'Google Maps API Key',
            s.googleMapKey ?? '',
            (v) => n.update((p) => p.copyWith(googleMapKey: v)),
            hint: '可选',
            obscure: true,
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// AI 服务抽屉 —— 原设置页的三个字段 + 连接测试合并至此。
class _AiSheet extends ConsumerStatefulWidget {
  const _AiSheet();
  @override
  ConsumerState<_AiSheet> createState() => _AiSheetState();
}

class _AiSheetState extends ConsumerState<_AiSheet> {
  bool _busy = false;
  AiPingResult? _last;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _last = null;
    });
    final s = ref.read(settingsProvider);
    final r = await ref.read(aiServiceProvider).ping(s);
    if (mounted) {
      setState(() {
        _busy = false;
        _last = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    final r = _last;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetTitle(
            'AI 服务',
            note: '用于 AI 旅行规划与旅行歌单。兼容 OpenAI 格式的 Base URL + Key。',
          ),
          _SheetField(Icons.link_rounded, 'Base URL', s.aiBaseUrl ?? '',
              (v) => n.update((p) => p.copyWith(aiBaseUrl: v))),
          _SheetField(Icons.key_rounded, 'API Key', s.aiApiKey ?? '',
              (v) => n.update((p) => p.copyWith(aiApiKey: v)),
              obscure: true),
          _SheetField(Icons.smart_toy_rounded, 'Model', s.aiModel,
              (v) => n.update((p) => p.copyWith(aiModel: v))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: r == null
                      ? Text('发一条 "ok" 验证当前配置',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant))
                      : Text(
                          r.success
                              ? '✅ ${r.latencyMs}ms — ${r.message}'
                              : '❌ ${r.message}',
                          style: TextStyle(
                              fontSize: 12,
                              color: r.success ? cs.primary : cs.error),
                        ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _run,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bolt_rounded, size: 18),
                  label: const Text('测试连接'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
