import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/prefs.dart';
import 'ai_service.dart';

/// 语音转文字 —— 走任何 OpenAI 兼容的 `/audio/transcriptions` 端点。
///
/// 默认配置是硅基流动的 `FunAudioLLM/SenseVoiceSmall`（免费），同一接口
/// 也覆盖 OpenAI（gpt-4o-mini-transcribe）、Groq（whisper-large-v3-turbo）
/// 和自建 whisper（faster-whisper-server 等开源方案）。
class SttService {
  final Dio _dio = Dio();

  /// 把一段录音转成文字。空白音频返回空字符串（不抛错，通话循环里
  /// 静默回到聆听态）。
  Future<String> transcribe({
    required AppSettings settings,
    required File audio,
  }) async {
    final base = settings.sttBaseUrl.trim().isEmpty
        ? 'https://api.siliconflow.cn/v1'
        : settings.sttBaseUrl.trim();
    final key = (settings.sttApiKey ?? '').trim().isNotEmpty
        ? settings.sttApiKey!.trim()
        : (settings.aiApiKey ?? '');
    final form = FormData.fromMap({
      'model': settings.sttModel,
      'file': await MultipartFile.fromFile(
        audio.path,
        filename: audio.path.split('/').last,
      ),
    });
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$base/audio/transcriptions',
        data: form,
        options: Options(
          headers: {'Authorization': 'Bearer $key'},
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      return (resp.data?['text'] ?? '').toString().trim();
    } on DioException catch (e) {
      throw AiException.fromDio(e);
    }
  }
}
