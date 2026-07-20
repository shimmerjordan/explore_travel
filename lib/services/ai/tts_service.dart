import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';

import '../../core/prefs.dart';
import 'ai_service.dart';

/// 文字转语音 —— 三个可切换引擎（跟小智 AI 一样的插拔思路）：
///
///  * `system`  —— 手机自带 TTS 引擎（Android TextToSpeech）。免费、离线、
///                 零流量；音色去系统设置里换。默认引擎。
///  * `volcano` —— 火山引擎豆包语音合成 HTTP 接口（付费，音色最好，
///                 湾湾小何 `zh_female_wanwanxiaohe_moon_bigtts` 就在这）。
///  * `openai`  —— 任何 OpenAI 兼容 `/audio/speech` 端点：硅基流动
///                 CosyVoice2（便宜）、OpenAI tts-1、自建开源 TTS 网关等。
///
/// 统一返回可直接播放的音频字节（网络引擎 MP3、系统引擎 WAV——just_audio
/// 按内容识别，不看后缀）。
///
/// 为什么没有 EdgeTTS：微软前端 2026 起按客户端指纹放行，Python 官方库能连，
/// Dart 网络栈同参数直接 403（本机与真机都验证过）。与其猫鼠游戏，不如把
/// 「免费」交给系统引擎。
class TtsService {
  final Dio _dio = Dio();

  FlutterTts? _sys;
  bool _sysReady = false;

  /// 系统引擎自己出声（speak），没有 bytes 可拿——调用方据此分流：
  /// true 走 [speakDirect]/[stopDirect]，false 走 [synthesize] + 自己播放。
  ///
  /// 为什么不用 synthesizeToFile 统一成 bytes：MIUI 等 ROM 上它的完成回调
  /// 经常不触发（Future 永久悬挂，真机实测），speak 路径可靠得多。
  bool playsItself(AppSettings settings) => settings.ttsEngine == 'system';

  Future<Uint8List> synthesize({
    required AppSettings settings,
    required String text,
  }) {
    switch (settings.ttsEngine) {
      case 'volcano':
        return _volcano(settings, text);
      case 'openai':
        return _openai(settings, text);
      default:
        throw AiException('系统 TTS 走 speakDirect，不产出音频字节');
    }
  }

  // ─── 系统 TTS（免费离线，直接朗读）────────────────────────────────────

  Future<FlutterTts> _sysTts(AppSettings s) async {
    final tts = _sys ??= FlutterTts();
    if (!_sysReady) {
      await tts.awaitSpeakCompletion(true);
      _sysReady = true;
    }
    await tts.setLanguage('zh-CN');
    // flutter_tts 的 0.5 ≈ 系统正常语速，把 0.5~2.0 的倍率映射过去。
    await tts.setSpeechRate((s.ttsSpeed * 0.5).clamp(0.1, 1.0));
    return tts;
  }

  /// 用系统引擎朗读一句话，播完返回。外层务必套 timeout —— 部分 ROM 的
  /// 完成回调不可靠，悬挂时靠超时兜底，绝不能卡死通话循环。
  Future<void> speakDirect({
    required AppSettings settings,
    required String text,
  }) async {
    try {
      final tts = await _sysTts(settings);
      final r = await tts.speak(text);
      if (r != 1) {
        throw AiException('系统 TTS 朗读失败（code=$r）——'
            '检查手机是否装了中文语音引擎（设置→系统/无障碍→文字转语音）');
      }
    } on AiException {
      rethrow;
    } catch (e) {
      throw AiException('系统 TTS 出错：$e');
    }
  }

  Future<void> stopDirect() async {
    try {
      await _sys?.stop();
    } catch (_) {}
  }

  // ─── 火山引擎豆包（付费音色，湾湾小何在此）────────────────────────────

  Future<Uint8List> _volcano(AppSettings s, String text) async {
    final appId = (s.volcTtsAppId ?? '').trim();
    final token = (s.volcTtsToken ?? '').trim();
    if (appId.isEmpty || token.isEmpty) {
      throw AiException('火山引擎 TTS 未配置：设置 → AI 服务 里填 AppID 和 Access Token');
    }
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        'https://openspeech.bytedance.com/api/v1/tts',
        options: Options(
          // 火山这个接口的鉴权就是这么写的：分号不是笔误。
          headers: {'Authorization': 'Bearer;$token'},
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
        ),
        data: {
          'app': {'appid': appId, 'token': 'access_token', 'cluster': s.volcTtsCluster},
          'user': {'uid': 'explore_journal'},
          'audio': {
            'voice_type': s.volcTtsVoice,
            'encoding': 'mp3',
            'speed_ratio': s.ttsSpeed,
          },
          'request': {
            'reqid': const Uuid().v4(),
            'text': text,
            'operation': 'query',
          },
        },
      );
      final j = resp.data ?? const {};
      final code = (j['code'] as num?)?.toInt();
      if (code != 3000) {
        throw AiException('火山 TTS 失败 code=$code：${j['message'] ?? j}');
      }
      return base64Decode(j['data'] as String);
    } on DioException catch (e) {
      throw AiException.fromDio(e);
    }
  }

  // ─── OpenAI 兼容 /audio/speech（硅基流动 CosyVoice2 等）───────────────

  Future<Uint8List> _openai(AppSettings s, String text) async {
    final base = s.ttsBaseUrl.trim().isEmpty
        ? 'https://api.siliconflow.cn/v1'
        : s.ttsBaseUrl.trim();
    final key = (s.ttsApiKey ?? '').trim().isNotEmpty
        ? s.ttsApiKey!.trim()
        : (s.aiApiKey ?? '');
    try {
      final resp = await _dio.post<List<int>>(
        '$base/audio/speech',
        options: Options(
          headers: {'Authorization': 'Bearer $key'},
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 40),
        ),
        data: {
          'model': s.ttsModel,
          'input': text,
          'voice': s.ttsVoice,
          'response_format': 'mp3',
          'speed': s.ttsSpeed,
        },
      );
      return Uint8List.fromList(resp.data ?? const []);
    } on DioException catch (e) {
      throw AiException.fromDio(e);
    }
  }
}
