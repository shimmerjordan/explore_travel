import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

/// First-run / "为什么后台不记录" troubleshooter.
///
/// Background recording on Android relies on FOUR independent grants,
/// any one of which can silently kill the trail:
///
///   1. Fine + background location — the OS gate
///   2. Notification permission (API 33+) — the foreground service
///      needs to be visible or the OS treats it as a regular bg task
///      after a few seconds
///   3. Battery optimisation exemption — the killer in practice; even
///      with all the above, "智能省电 / Adaptive Battery" will doze
///      the foreground service after the screen has been off for a
///      while
///   4. Vendor-specific "autostart / 自启动" — vivo / Xiaomi / OPPO /
///      Huawei each have their own UI for this, none of which is
///      addressable from the standard Android API. We can deep-link
///      to each via vendor-specific intents.
///
/// This screen surfaces all four in one place with live status, fixes
/// the easy ones inline, and deep-links to system settings for the
/// rest.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});
  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  // Status snapshots — refreshed on screen open and whenever the user
  // returns to the app from a settings deep-link.
  PermissionStatus? _fgLocation;
  PermissionStatus? _bgLocation;
  PermissionStatus? _notif;
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final fg = await Permission.locationWhenInUse.status;
    final bg = Platform.isAndroid
        ? await Permission.locationAlways.status
        : await Permission.locationAlways.status;
    final notif = await Permission.notification.status;
    final batt = Platform.isAndroid
        ? await FlutterForegroundTask.isIgnoringBatteryOptimizations
        : true;
    if (!mounted) return;
    setState(() {
      _fgLocation = fg;
      _bgLocation = bg;
      _notif = notif;
      _batteryExempt = batt;
    });
  }

  Future<void> _askFg() async {
    await Permission.locationWhenInUse.request();
    await _refresh();
  }

  Future<void> _askBg() async {
    // On Android 11+, you must FIRST have foreground granted, and the
    // OS bounces the user to the system settings page rather than
    // showing an inline dialog. permission_handler abstracts that for
    // us — calling .request() either pops the dialog (older OS) or
    // opens the right settings page (newer OS).
    if (_fgLocation != PermissionStatus.granted) {
      await Permission.locationWhenInUse.request();
    }
    await Permission.locationAlways.request();
    await _refresh();
  }

  Future<void> _askNotif() async {
    await Permission.notification.request();
    await _refresh();
  }

  Future<void> _askBattery() async {
    // foreground_task wraps the
    // ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS dialog. Returns the
    // current state regardless — we re-check on resume.
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    await _refresh();
  }

  /// Best-effort deep-link into vendor-specific "autostart" screens.
  /// These intents are unofficial and may break between ROM versions;
  /// each opens what we think is the right page or, if that fails,
  /// falls back to the system app-settings page (which on every ROM
  /// has the autostart toggle somewhere reachable).
  Future<void> _openAutostart() async {
    if (!Platform.isAndroid) return;
    final candidates = <List<String>>[
      // vivo
      ['com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.BgStartUpManager'],
      ['com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity'],
      ['com.vivo.permissionmanager',
        'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'],
      // Xiaomi / MIUI
      ['com.miui.securitycenter',
        'com.miui.permcenter.autostart.AutoStartManagementActivity'],
      // OPPO / ColorOS
      ['com.coloros.safecenter',
        'com.coloros.safecenter.permission.startup.StartupAppListActivity'],
      ['com.coloros.safecenter',
        'com.coloros.safecenter.startupapp.StartupAppListActivity'],
      ['com.oppo.safe', 'com.oppo.safe.permission.startup.StartupAppListActivity'],
      // Huawei / EMUI / HarmonyOS
      ['com.huawei.systemmanager',
        'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity'],
      ['com.huawei.systemmanager',
        'com.huawei.systemmanager.optimize.process.ProtectActivity'],
      // Letv / Honor / Samsung — fewer common
      ['com.samsung.android.lool', 'com.samsung.android.sm.ui.battery.BatteryActivity'],
    ];
    for (final c in candidates) {
      try {
        await AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: c[0],
          componentName: '${c[0]}/${c[1]}',
        ).launch();
        return; // first success wins
      } catch (_) {
        continue;
      }
    }
    // Fallback: open the app's own settings page; user navigates to
    // autostart from there. Always works.
    try {
      await openAppSettings();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allGood = _fgLocation == PermissionStatus.granted &&
        _bgLocation == PermissionStatus.granted &&
        (_notif == PermissionStatus.granted ||
            _notif == PermissionStatus.permanentlyDenied ||
            !Platform.isAndroid) &&
        (_batteryExempt == true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('权限与后台'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status banner ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: allGood ? cs.primaryContainer : cs.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  allGood ? Icons.check_circle_outline : Icons.warning_amber,
                  color: allGood ? cs.onPrimaryContainer : cs.onErrorContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    allGood
                        ? '全部权限已就绪，后台记录应该稳定工作'
                        : '后台记录可能不稳定，按下面的清单逐项授权',
                    style: TextStyle(
                      color: allGood
                          ? cs.onPrimaryContainer
                          : cs.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          _PermissionRow(
            icon: Icons.my_location_rounded,
            title: '前台定位 · 使用应用时',
            description: '基础权限，没有它整个 GPS 都不能用。',
            status: _statusLabel(_fgLocation),
            isGood: _fgLocation == PermissionStatus.granted,
            actionLabel: _fgLocation == PermissionStatus.granted ? '已授予' : '授权',
            onAction: _fgLocation == PermissionStatus.granted ? null : _askFg,
          ),
          _PermissionRow(
            icon: Icons.location_on_outlined,
            title: '后台定位 · 始终允许',
            description:
                '屏幕熄屏 / 应用切到后台后还能继续记录的核心权限。Android 11+ 会跳到系统设置页，请手动选「始终允许」。',
            status: _statusLabel(_bgLocation),
            isGood: _bgLocation == PermissionStatus.granted,
            actionLabel: _bgLocation == PermissionStatus.granted ? '已授予' : '前往设置',
            onAction: _bgLocation == PermissionStatus.granted ? null : _askBg,
          ),
          _PermissionRow(
            icon: Icons.notifications_outlined,
            title: '通知权限',
            description:
                '前台服务必须显示一条常驻通知，否则系统几秒钟后就会回收。Android 13+ 才会主动询问。',
            status: _statusLabel(_notif),
            isGood: _notif == PermissionStatus.granted,
            actionLabel: _notif == PermissionStatus.granted ? '已授予' : '授权',
            onAction: _notif == PermissionStatus.granted ? null : _askNotif,
          ),
          _PermissionRow(
            icon: Icons.battery_charging_full_rounded,
            title: '电池优化白名单',
            description:
                '把本应用加入电池优化白名单 / 「无限制」/ 「不优化」。这是后台记录死掉最常见的原因。',
            status: _batteryExempt == null
                ? '检查中…'
                : (_batteryExempt! ? '已豁免' : '受限'),
            isGood: _batteryExempt == true,
            actionLabel: _batteryExempt == true ? '已豁免' : '请求豁免',
            onAction: _batteryExempt == true ? null : _askBattery,
          ),
          _PermissionRow(
            icon: Icons.power_settings_new_rounded,
            title: '允许自启动 / 后台运行',
            description:
                '小米 / vivo / OPPO / 华为 / 荣耀 的「自启动 / 关联启动 / 后台运行」开关。系统 API 查不到状态，需要你手动确认。',
            status: '请前往设置确认',
            // We can't check this state programmatically — mark
            // neutral so the user doesn't read "受限" as a real error.
            isGood: null,
            actionLabel: '打开设置',
            onAction: _openAutostart,
          ),

          const SizedBox(height: 24),

          // ── Vendor-specific tips ──
          Card(
            color: cs.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('厂商小贴士',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  const Text(
                    '• vivo / iQOO：设置 → 电池 → 后台高耗电 → 允许 · 「Explore Journal」\n'
                    '• 小米 / Redmi：设置 → 应用 → Explore Journal → 省电策略 → 无限制\n'
                    '• OPPO / 一加：设置 → 电池 → 高耗电应用 → 允许\n'
                    '• 华为 / 荣耀：设置 → 应用 → Explore Journal → 电池 → 允许后台活动\n'
                    '• 三星：设置 → 电池 → 允许后台活动\n'
                    '\n'
                    '另外把这个应用「锁定到最近任务列表」也能显著提高存活率（任务管理器里下拉小锁图标）。',
                    style: TextStyle(fontSize: 12, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(PermissionStatus? s) {
    if (s == null) return '检查中…';
    switch (s) {
      case PermissionStatus.granted:
        return '已授予';
      case PermissionStatus.denied:
        return '未授予';
      case PermissionStatus.restricted:
        return '受限';
      case PermissionStatus.limited:
        return '部分授予';
      case PermissionStatus.permanentlyDenied:
        return '已拒绝（去设置开）';
      case PermissionStatus.provisional:
        return '临时';
    }
  }
}

class _PermissionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String status;
  /// `true` = green-check, `false` = red-x, `null` = neutral question
  /// mark (used for things we can't programmatically detect, like
  /// vendor autostart).
  final bool? isGood;
  final String actionLabel;
  final VoidCallback? onAction;
  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.isGood,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stateColor = isGood == true
        ? Colors.green
        : isGood == false
            ? cs.error
            : cs.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: stateColor.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: stateColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Row(
                      children: [
                        Icon(
                          isGood == true
                              ? Icons.check_circle
                              : isGood == false
                                  ? Icons.cancel_outlined
                                  : Icons.help_outline,
                          size: 14,
                          color: stateColor,
                        ),
                        const SizedBox(width: 4),
                        Text(status,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: stateColor,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ),
              FilledButton.tonal(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(actionLabel, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(description,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
