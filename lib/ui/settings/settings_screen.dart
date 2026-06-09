import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import '../../app/providers.dart';
import '../../models/models.dart';
import '../../services/ai/ai_service.dart';
import '../../services/fog/fow_compat.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('设置',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              _SectionHeader('记录与迷雾'),
              _buildTile(
                context,
                icon: Icons.speed_rounded,
                title: '记录模式',
                subtitle: s.recordingMode.label,
                trailing: SegmentedButton<RecordingMode>(
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: RecordingMode.values
                      .map((m) => ButtonSegment(
                          value: m,
                          label: Text(m.label,
                              style: const TextStyle(fontSize: 11))))
                      .toList(),
                  selected: {s.recordingMode},
                  onSelectionChanged: (v) =>
                      n.update((p) => p.copyWith(recordingMode: v.first)),
                ),
              ),
              _buildTile(
                context,
                icon: Icons.palette_rounded,
                title: '迷雾颜色',
                trailing: GestureDetector(
                  onTap: () => _pickColor(context, s.fogColor,
                      (c) => n.update((p) => p.copyWith(fogColor: c))),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Color(s.fogColor),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: cs.outline.withValues(alpha: 0.3), width: 1.5),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('迷雾浓度',
                        style: TextStyle(
                            color: cs.onSurface, fontWeight: FontWeight.w500)),
                    Slider(
                      value: s.fogOpacity,
                      min: 0.3,
                      max: 1.0,
                      divisions: 20,
                      label: s.fogOpacity.toStringAsFixed(2),
                      onChanged: (v) =>
                          n.update((p) => p.copyWith(fogOpacity: v)),
                    ),
                    Text('轨迹粗细',
                        style: TextStyle(
                            color: cs.onSurface, fontWeight: FontWeight.w500)),
                    Slider(
                      // Visible recorded-path width. Stored per-point at
                      // record time, so changing this only affects points
                      // recorded afterwards — existing trails are untouched.
                      value: s.trailWidth,
                      min: 2,
                      max: 60,
                      divisions: 58,
                      label: '${s.trailWidth.toStringAsFixed(0)} m',
                      onChanged: (v) =>
                          n.update((p) => p.copyWith(trailWidth: v)),
                    ),
                    Text('擦除 / 涂抹半径',
                        style: TextStyle(
                            color: cs.onSurface, fontWeight: FontWeight.w500)),
                    Slider(
                      // Brush radius for the map add/erase tools only —
                      // independent of the trail thickness above.
                      value: s.fogPenRadius,
                      min: 5,
                      max: 200,
                      divisions: 39,
                      label: '${s.fogPenRadius.toStringAsFixed(0)} m',
                      onChanged: (v) =>
                          n.update((p) => p.copyWith(fogPenRadius: v)),
                    ),
                  ],
                ),
              ),
              _SectionHeader('地图'),
              _buildTile(
                context,
                icon: Icons.map_rounded,
                title: '地图提供商',
                trailing: SegmentedButton<MapProvider>(
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
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
                  selected: {s.mapProvider},
                  onSelectionChanged: (v) =>
                      n.update((p) => p.copyWith(mapProvider: v.first)),
                ),
              ),
              _buildTile(
                context,
                icon: Icons.screen_rotation_rounded,
                title: '允许地图旋转',
                subtitle: '关闭时双指只缩放、不旋转（默认）。开启后可双指旋转，'
                    '小幅度转动仍会被忽略，右上角指南针可一键回正北。',
                trailing: Switch.adaptive(
                  value: s.allowMapRotation,
                  onChanged: (v) =>
                      n.update((p) => p.copyWith(allowMapRotation: v)),
                ),
              ),
              _InfoTile(
                icon: Icons.info_outline_rounded,
                title: '关于地图 API Key',
                subtitle:
                    '高德/Google 的栅格瓦片当前是公共直连，无需 Key 即可显示。\n'
                    'Key 用于：① 离线瓦片缓存配额  ② 反向地理编码（地名搜索）  ③ POI 检索。\n'
                    '不填也能正常用地图。\n\n'
                    'tile.openstreetmap.org 从国内访问经常超时，建议用高德或'
                    '在下面填一个国内可达的 OSM 镜像。',
              ),
              _TextSetting(
                Icons.link_rounded,
                'OSM 瓦片自定义 URL',
                s.customOsmTileUrl,
                (v) => n.update((p) => p.copyWith(customOsmTileUrl: v)),
                hint: '留空用默认；占位符 {z}/{x}/{y}',
              ),
              _TextSetting(
                Icons.key_rounded,
                '高德 API Key',
                s.amapApiKey,
                (v) => n.update((p) => p.copyWith(amapApiKey: v)),
                hint: '可选，用于地名搜索 / POI',
                obscure: true,
              ),
              _TextSetting(
                Icons.key_rounded,
                'Google Maps API Key',
                s.googleMapKey,
                (v) => n.update((p) => p.copyWith(googleMapKey: v)),
                hint: '可选',
                obscure: true,
              ),
              _SectionHeader('AI'),
              _TextSetting(Icons.link_rounded, 'AI Base URL', s.aiBaseUrl,
                  (v) => n.update((p) => p.copyWith(aiBaseUrl: v))),
              _TextSetting(Icons.key_rounded, 'AI API Key', s.aiApiKey,
                  (v) => n.update((p) => p.copyWith(aiApiKey: v)),
                  obscure: true),
              _TextSetting(Icons.smart_toy_rounded, 'AI Model', s.aiModel,
                  (v) => n.update((p) => p.copyWith(aiModel: v))),
              const _AiTestTile(),
              _SectionHeader('云端备份'),
              _ActionTile(
                icon: Icons.cloud_sync_rounded,
                title: 'WebDAV 备份与恢复',
                onTap: () => context.push('/backup'),
              ),
              _SectionHeader('Fog of World 兼容'),
              _ActionTile(
                icon: Icons.file_download_rounded,
                title: '导入 FOW 数据（Sync 文件夹）',
                onTap: () async {
                  final fog = ref.read(fogEngineProvider);
                  final activeLayer = ref.read(activeLayerIdProvider);
                  final docsDir = await getApplicationDocumentsDirectory();
                  final fowDir = '${docsDir.path}/fow_import';
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('请将 FOW Sync 文件放入: $fowDir')));
                  }
                  try {
                    final count = await importFowDirectory(
                      dirPath: fowDir,
                      engine: fog,
                      layerId: activeLayer,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('已导入 $count 个 block')));
                    }
                    ref.read(fogRefreshProvider.notifier).state++;
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('导入失败：$e')));
                    }
                  }
                },
              ),
              _ActionTile(
                icon: Icons.file_upload_rounded,
                title: '导出为 FOW 格式',
                onTap: () async {
                  final fog = ref.read(fogEngineProvider);
                  final db = ref.read(dbProvider);
                  final layers = (await db.allLayers())
                      .where((l) => l.visible)
                      .map((l) => l.id)
                      .toList();
                  final docsDir = await getApplicationDocumentsDirectory();
                  final fowDir = '${docsDir.path}/fow_export';
                  try {
                    final count = await exportFowDirectory(
                      dirPath: fowDir,
                      engine: fog,
                      layerIds: layers,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('已导出 $count 个 tile 到: $fowDir')));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('导出失败：$e')));
                    }
                  }
                },
              ),
              _SectionHeader('权限与后台'),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('后台记录设置'),
                subtitle: const Text(
                    '始终允许定位 / 电池豁免 / 厂商自启动 — 排查"后台不记录"'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/permissions'),
              ),
              _SectionHeader('组队'),
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: const Text('组队配置'),
                subtitle: const Text('传输方式 / 群组 ID / 昵称 / 共享口令'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/group/setup'),
              ),
              _SectionHeader('关于'),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('关于 Explore Journal'),
                subtitle:
                    const Text('版本号 / 仓库 / 文档 / 贡献者 / 许可证'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/about'),
              ),
              const SizedBox(height: 60),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context,
      {required IconData icon,
      required String title,
      String? subtitle,
      Widget? trailing}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: trailing,
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

Future<bool> _confirm(BuildContext context, String msg) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定')),
      ],
    ),
  );
  return r ?? false;
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

class _TextSetting extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final Function(String) onSubmit;
  final bool obscure;
  final String? hint;
  const _TextSetting(this.icon, this.label, this.value, this.onSubmit,
      {this.obscure = false, this.hint});

  @override
  Widget build(BuildContext context) {
    final shown = value == null || value!.isEmpty
        ? (hint ?? '未设置')
        : (obscure ? '••••••' : value!);
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(
        shown,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        final ctrl = TextEditingController(text: value ?? '');
        final r = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(label),
            content: TextField(
              controller: ctrl,
              obscureText: obscure,
              autofocus: true,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(context, ctrl.text),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (r != null) onSubmit(r);
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _ActionTile(
      {required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _InfoTile(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One-shot AI connectivity probe. Useful because the music / planner pages
/// silently spin forever when the configured model name is wrong, the API
/// key is bad, or the base URL is unreachable. This tile gives a specific
/// failure reason instead.
class _AiTestTile extends ConsumerStatefulWidget {
  const _AiTestTile();
  @override
  ConsumerState<_AiTestTile> createState() => _AiTestTileState();
}

class _AiTestTileState extends ConsumerState<_AiTestTile> {
  bool _busy = false;
  AiPingResult? _last;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _last = null;
    });
    final s = ref.read(settingsProvider);
    final r = await ref.read(aiServiceProvider).ping(s);
    if (mounted) setState(() {
      _busy = false;
      _last = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _last;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(
              r == null
                  ? Icons.bolt_rounded
                  : (r.success ? Icons.check_circle : Icons.error_outline),
              color: r == null
                  ? null
                  : (r.success ? Colors.greenAccent : Colors.redAccent),
            ),
      title: const Text('测试 AI 连接'),
      subtitle: r == null
          ? const Text('给当前 base / key / model 发一条 "ok" 验证')
          : Text(
              r.success
                  ? '✅ ${r.latencyMs}ms — 模型回复：${r.message}'
                  : '❌ ${r.message}',
              style: TextStyle(
                  color: r.success ? cs.primary : Colors.redAccent),
            ),
      trailing: FilledButton(
        onPressed: _busy ? null : _run,
        child: const Text('测试'),
      ),
    );
  }
}
