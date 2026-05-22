import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../core/prefs.dart';

class AiPingResult {
  final bool success;
  final String message;
  final int? latencyMs;
  AiPingResult._(this.success, this.message, this.latencyMs);
  factory AiPingResult.ok(String reply, int ms) =>
      AiPingResult._(true, reply, ms);
  factory AiPingResult.fail(String msg) => AiPingResult._(false, msg, null);
}

/// Chat-completion compatible AI client (OpenAI / SiliconFlow / DeepSeek /
/// OpenRouter — anything that speaks the OpenAI /chat/completions schema).
///
/// Provides both a one-shot [chat] and a [chatStream] variant. Streaming is
/// the path the UI uses for trip planning so the user sees tokens as they
/// arrive — DeepSeek-R1 can spend 30-60s thinking before any output, which
/// looks like a hang without streaming.
class AiService {
  final Dio _dio = Dio();

  Future<String> chat({
    required AppSettings settings,
    required List<Map<String, String>> messages,
    double temperature = 0.7,
    int maxTokens = 1024,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final base = settings.aiBaseUrl ?? 'https://api.siliconflow.cn/v1';
    final url = '$base/chat/completions';
    final resp = await _dio.post(
      url,
      options: Options(
        headers: {
          'Authorization': 'Bearer ${settings.aiApiKey ?? ''}',
          'Content-Type': 'application/json',
        },
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
      data: {
        'model': settings.aiModel,
        'messages': messages,
        'temperature': temperature,
        'max_tokens': maxTokens,
      },
    );
    final data = resp.data as Map<String, dynamic>;
    return (data['choices'][0]['message']['content'] as String).trim();
  }

  /// Quick health probe for the "测试" button: sends a 1-token round-trip
  /// with a 10-second timeout, returns either the model's echoed reply or
  /// a human-readable error string. Designed for diagnostics — never
  /// throws.
  Future<AiPingResult> ping(AppSettings settings) async {
    if ((settings.aiBaseUrl ?? '').isEmpty) {
      return AiPingResult.fail('未配置 AI Base URL');
    }
    if ((settings.aiApiKey ?? '').isEmpty) {
      return AiPingResult.fail('未配置 AI API Key');
    }
    if (settings.aiModel.isEmpty) {
      return AiPingResult.fail('未配置 AI Model');
    }
    final start = DateTime.now();
    try {
      final reply = await chat(
        settings: settings,
        messages: [
          {'role': 'user', 'content': '回答"ok"两个字符即可。'},
        ],
        temperature: 0,
        maxTokens: 16,
        timeout: const Duration(seconds: 15),
      );
      final ms = DateTime.now().difference(start).inMilliseconds;
      return AiPingResult.ok(reply, ms);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final body = e.response?.data?.toString();
      String detail;
      if (code != null) {
        detail = 'HTTP $code';
        if (body != null && body.isNotEmpty) {
          detail += '：${body.length > 200 ? "${body.substring(0, 200)}…" : body}';
        }
      } else {
        detail = e.message ?? e.type.toString();
      }
      return AiPingResult.fail(detail);
    } catch (e) {
      return AiPingResult.fail('$e');
    }
  }

  /// AI-driven random trip suggestion.
  ///
  /// Throws [AiException] with a human-readable message on failure (instead
  /// of a raw DioException) so the UI can show a useful snackbar without
  /// having to know about dio internals. Uses a 2-minute timeout because
  /// 1500-token outputs from cheaper models can easily take 60-90 s.
  Future<String> suggestTrip({
    required AppSettings settings,
    required int budgetCny,
    required int days,
    required int people,
    required String preferences,
    String? origin,
  }) async {
    final system = '''
你是旅行规划助手。根据用户输入给出一份具体可行的中文 Markdown 旅行方案。

格式要求：
- 用 ## 二级标题区分"目的地"、"行程概览"、"逐日安排"、"预算拆解"四个部分
- 整体控制在 600 字左右，简洁、可执行
- 不要寒暄、不要重复用户输入、不要插入图片链接（图片会让加载变慢，纯文字即可）

直接给方案。
''';
    final user = '''
预算：$budgetCny 元
出发地：${origin ?? '不限'}
天数：$days 天
人数：$people 人
偏好/期待：$preferences
''';
    try {
      return await chat(
        settings: settings,
        messages: [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        temperature: 0.9,
        // 800 tokens ≈ 600 中文字符；多数模型 30-60s 内能跑完。
        maxTokens: 800,
        timeout: const Duration(minutes: 30),
      );
    } on DioException catch (e) {
      throw AiException.fromDio(e);
    }
  }

  /// Streaming chat: yields each incremental content chunk as it arrives.
  /// Caller should `await for` the stream and append to a buffer.
  ///
  /// Why this exists: a normal [chat] call only returns when the model is
  /// fully done, which for DeepSeek-R1 (reasoning mode) routinely means 60+
  /// seconds of nothing — looks like a hang. SSE lets the user see the
  /// first sentence ~1s in. Same OpenAI-format `data: {...}\n\n` SSE that
  /// every provider in this ecosystem speaks.
  ///
  /// Errors are surfaced by adding an [AiException] to the stream and then
  /// closing it.
  Stream<String> chatStream({
    required AppSettings settings,
    required List<Map<String, String>> messages,
    double temperature = 0.7,
    int maxTokens = 1024,
    Duration timeout = const Duration(minutes: 30),
    CancelToken? cancelToken,
  }) async* {
    final base = settings.aiBaseUrl ?? 'https://api.siliconflow.cn/v1';
    final url = '$base/chat/completions';
    final Response<ResponseBody> resp;
    try {
      resp = await _dio.post<ResponseBody>(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${settings.aiApiKey ?? ''}',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
        data: {
          'model': settings.aiModel,
          'messages': messages,
          'temperature': temperature,
          'max_tokens': maxTokens,
          'stream': true,
        },
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      throw AiException.fromDio(e);
    }
    final stream = resp.data!.stream;
    final buffer = StringBuffer();
    try {
    await for (final chunk in stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      // Process whole SSE events ("data: {...}\n\n").
      while (true) {
        final s = buffer.toString();
        final i = s.indexOf('\n\n');
        if (i < 0) break;
        final event = s.substring(0, i);
        buffer
          ..clear()
          ..write(s.substring(i + 2));
        for (final line in event.split('\n')) {
          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty) continue;
          if (payload == '[DONE]') return;
          try {
            final j = jsonDecode(payload) as Map<String, dynamic>;
            final delta = (j['choices'] as List?)?.firstOrNull
                as Map<String, dynamic>?;
            final content = (delta?['delta'] as Map?)?['content']
                ?.toString();
            if (content != null && content.isNotEmpty) yield content;
          } catch (_) {
            // Tolerate junk lines (some providers send keepalive comments
            // like ": ping").
          }
        }
      }
    }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      rethrow;
    }
  }

  /// Continue an existing planner conversation with a follow-up question.
  /// Caller passes the full message history so the model has context.
  /// Throws [AiException] on failure.
  Future<String> followUp({
    required AppSettings settings,
    required List<Map<String, String>> history,
    required String question,
  }) async {
    final messages = [
      ...history,
      {'role': 'user', 'content': question},
    ];
    try {
      return await chat(
        settings: settings,
        messages: messages,
        temperature: 0.7,
        maxTokens: 800,
        timeout: const Duration(minutes: 30),
      );
    } on DioException catch (e) {
      throw AiException.fromDio(e);
    }
  }

  /// Suggest a song mood/playlist based on travel context (place, time,
  /// weather, recent music). Returns up to 10 search keywords to feed the
  /// music API.
  Future<List<String>> suggestSongKeywords({
    required AppSettings settings,
    required String placeDescription,
    required String moodHint,
    int count = 10,
  }) async {
    try {
      final reply = await chat(
        settings: settings,
        messages: [
          {
            'role': 'system',
            'content':
                '你是旅行歌单 DJ，根据当前所在地与情绪给出 $count 个适合搜索的歌曲关键词。'
                    '每行一个，可以是歌名、歌名+歌手、或情绪短语；不要序号、不要解释、不要空行。'
                    '尽量风格多样不要重复。'
          },
          {
            'role': 'user',
            'content': '当前所在地描述：$placeDescription\n现在的情绪/路况：$moodHint'
          },
        ],
        temperature: 0.95,
        maxTokens: 400,
        timeout: const Duration(seconds: 60),
      );
      return reply
          .split('\n')
          .map((l) => l.trim().replaceFirst(RegExp(r'^\d+[\.\)、]\s*'), ''))
          .where((l) => l.isNotEmpty)
          .take(count)
          .toList();
    } on DioException catch (e) {
      throw AiException.fromDio(e);
    }
  }
}

/// User-friendly wrapper around DioException. Carries the actual HTTP body
/// from the AI provider when present (which usually contains the precise
/// reason: "model not found", "rate limited", "context too long", etc.).
class AiException implements Exception {
  final String message;
  AiException(this.message);

  factory AiException.fromDio(DioException e) {
    final code = e.response?.statusCode;
    final body = e.response?.data;
    String detail;
    if (code != null) {
      detail = 'HTTP $code';
      if (body != null) {
        final asString = body is String ? body : body.toString();
        if (asString.isNotEmpty) {
          detail += '：${asString.length > 300 ? "${asString.substring(0, 300)}…" : asString}';
        }
      }
    } else {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
          detail = '连接超时——base URL 是否对、网络通不通？';
          break;
        case DioExceptionType.receiveTimeout:
          detail = '响应超时——模型生成太慢或被限流，换更快的模型或重试';
          break;
        case DioExceptionType.connectionError:
          detail = '连不上 ${e.requestOptions.uri.host}——网络/DNS/代理问题';
          break;
        default:
          detail = e.message ?? e.type.toString();
      }
    }
    return AiException(detail);
  }

  @override
  String toString() => message;
}
