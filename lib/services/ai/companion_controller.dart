import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/prefs.dart';
import '../geo/geocoding_service.dart';
import 'ai_service.dart';
import 'stt_service.dart';
import 'tts_service.dart';

/// 通话状态：off = 未通话；其余三态构成 聆听 → 思考 → 说话 的循环
/// （小智 AI 的 ASR → LLM → TTS 管线，这里在端上编排）。
enum CallPhase { off, listening, thinking, speaking }

class CompanionMessage {
  final String role; // 'user' | 'assistant'
  String text;
  final String? imagePath;
  final DateTime at;
  bool streaming;
  bool error;

  CompanionMessage({
    required this.role,
    required this.text,
    this.imagePath,
    DateTime? at,
    this.streaming = false,
    this.error = false,
  }) : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (imagePath != null) 'image': imagePath,
        'at': at.toIso8601String(),
        if (error) 'error': true,
      };

  factory CompanionMessage.fromJson(Map<String, dynamic> j) =>
      CompanionMessage(
        role: j['role']?.toString() ?? 'assistant',
        text: j['text']?.toString() ?? '',
        imagePath: j['image']?.toString(),
        at: DateTime.tryParse(j['at']?.toString() ?? ''),
        error: j['error'] == true,
      );
}

/// 地图页 AI 旅伴的大脑：文字聊天（可带图）、历史持久化、语音通话状态机。
/// 生命周期挂在全局 provider 上——卡片最小化、甚至离开地图页，通话照常进行。
class CompanionController extends ChangeNotifier {
  final AiService ai;
  final SttService stt;
  final TtsService tts;
  final AppSettings Function() settingsOf;
  final GeocodingService Function() geocodingOf;

  CompanionController({
    required this.ai,
    required this.stt,
    required this.tts,
    required this.settingsOf,
    required this.geocodingOf,
  }) {
    _restore();
  }

  // ─── 对话状态 ───────────────────────────────────────────────────────────

  final List<CompanionMessage> messages = [];
  bool busy = false; // 文字回复流式生成中
  bool cardOpen = false;
  int unread = 0;

  // ─── 通话状态 ───────────────────────────────────────────────────────────

  CallPhase callPhase = CallPhase.off;
  String callHint = '';
  bool get inCall => callPhase != CallPhase.off;

  final AudioRecorder _rec = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  CancelToken? _cancel;
  bool _callAlive = false;
  bool _interrupted = false;
  int _ttsSeq = 0;

  // ─── 位置上下文（地图页喂进来，让旅伴知道用户在哪）─────────────────────

  double? _ctxLat;
  double? _ctxLng;
  String _ctxPlace = '';

  void updatePosition(double? lat, double? lng) {
    if (lat == null || lng == null) return;
    _ctxLat = lat;
    _ctxLng = lng;
    // 反查地名尽力而为：本地缓存秒回，网络失败就只报坐标。
    () async {
      try {
        final r = await geocodingOf()
            .resolve(lat, lng)
            .timeout(const Duration(seconds: 4));
        final parts = <String>[];
        for (final p in [r.country, r.province, r.city]) {
          if (p.isNotEmpty && !parts.contains(p)) parts.add(p);
        }
        if (parts.isNotEmpty) _ctxPlace = parts.join(' · ');
      } catch (_) {}
    }();
  }

  void setCardOpen(bool open) {
    cardOpen = open;
    if (open && unread != 0) {
      unread = 0;
    }
    notifyListeners();
  }

  // ─── 历史持久化（JSON 文件，最多 200 条）────────────────────────────────

  static const _historyCap = 200;
  File? _historyFile;

  Future<File> _history() async {
    if (_historyFile != null) return _historyFile!;
    final dir = await getApplicationDocumentsDirectory();
    return _historyFile = File('${dir.path}/ai_companion_history.json');
  }

  Future<void> _restore() async {
    try {
      final f = await _history();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      messages
        ..clear()
        ..addAll(list
            .whereType<Map<String, dynamic>>()
            .map(CompanionMessage.fromJson));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final f = await _history();
      final keep = messages.length > _historyCap
          ? messages.sublist(messages.length - _historyCap)
          : messages;
      await f.writeAsString(
          jsonEncode([for (final m in keep) m.toJson()]));
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    if (busy || inCall) return;
    messages.clear();
    notifyListeners();
    await _persist();
  }

  // ─── LLM 消息组装 ───────────────────────────────────────────────────────

  static const _defaultPersona = '你是「小岚」，旅行手账 App 里的像素小人旅行搭子，陪用户走路、'
      '坐车、逛城市。性格轻快、好奇、真诚，偶尔一点小幽默，从不说教。'
      '你擅长路线规划、当地美食、冷门景点、交通换乘和旅行摄影。'
      '默认用简体中文，回答简洁直接，只有列清单时才用 markdown。';

  String _systemPrompt({required bool voice}) {
    final s = settingsOf();
    final b = StringBuffer(
        s.aiPersona.trim().isEmpty ? _defaultPersona : s.aiPersona.trim());
    final now = DateTime.now();
    const wd = ['一', '二', '三', '四', '五', '六', '日'];
    b.write('\n当前时间：${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}（周${wd[now.weekday - 1]}）');
    if (_ctxLat != null) {
      final place = _ctxPlace.isEmpty ? '' : '$_ctxPlace，';
      b.write('\n用户此刻位置：$place坐标 '
          '${_ctxLat!.toStringAsFixed(3)}, ${_ctxLng!.toStringAsFixed(3)}。');
    }
    if (voice) {
      b.write('\n现在是语音通话：像朋友打电话那样口语化，每次最多两三句话，'
          '不用 markdown、不用表情符号、不用列表。');
    }
    return b.toString();
  }

  static String _mimeOf(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// 组装发给 LLM 的消息：system + 最近 24 条历史。只有**本轮**的图片以
  /// vision 内容数组随行；历史里的旧图降级为「[图片]」占位（省 token）。
  Future<List<Map<String, dynamic>>> _llmMessages({required bool voice}) async {
    final out = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt(voice: voice)},
    ];
    final window = messages.length > 24
        ? messages.sublist(messages.length - 24)
        : List.of(messages);
    for (var i = 0; i < window.length; i++) {
      final m = window[i];
      if (m.error || (m.streaming && m.text.isEmpty)) continue;
      final isLast = identical(m, window.last);
      if (m.imagePath != null && isLast && m.role == 'user') {
        try {
          final bytes = await File(m.imagePath!).readAsBytes();
          out.add({
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:${_mimeOf(m.imagePath!)};base64,'
                      '${base64Encode(bytes)}'
                },
              },
              {'type': 'text', 'text': m.text.isEmpty ? '看看这张照片' : m.text},
            ],
          });
          continue;
        } catch (_) {}
      }
      out.add({
        'role': m.role,
        'content': m.imagePath != null ? '[图片] ${m.text}' : m.text,
      });
    }
    return out;
  }

  // ─── 文字聊天 ───────────────────────────────────────────────────────────

  Future<void> sendText(String text, {String? imagePath}) async {
    final t = text.trim();
    if (t.isEmpty && imagePath == null) return;
    if (busy || inCall) return;
    messages.add(
        CompanionMessage(role: 'user', text: t, imagePath: imagePath));
    final reply = CompanionMessage(role: 'assistant', text: '', streaming: true);
    messages.add(reply);
    busy = true;
    notifyListeners();

    final s = settingsOf();
    final hasImage = imagePath != null;
    final model = hasImage && s.aiVisionModel.trim().isNotEmpty
        ? s.aiVisionModel.trim()
        : null;
    _cancel = CancelToken();
    try {
      final msgs = await _llmMessages(voice: false);
      await for (final delta in ai.chatStream(
        settings: s,
        messages: msgs,
        modelOverride: model,
        maxTokens: 1024,
        timeout: const Duration(minutes: 3),
        cancelToken: _cancel,
      )) {
        reply.text += delta;
        notifyListeners();
      }
      if (reply.text.isEmpty) {
        reply.text = '（对方沉默了……模型没有返回内容，试试换个模型？）';
      }
    } catch (e) {
      reply.error = true;
      reply.text = '出错了：$e';
    } finally {
      reply.streaming = false;
      busy = false;
      _cancel = null;
      if (!cardOpen) unread++;
      notifyListeners();
      await _persist();
    }
  }

  /// 停止当前文字回复的流式生成（保留已生成部分）。
  void stopStreaming() {
    _cancel?.cancel();
  }

  // ─── 语音通话 ───────────────────────────────────────────────────────────

  Future<String?> startCall() async {
    if (inCall) return null;
    final s = settingsOf();
    if ((s.aiApiKey ?? '').isEmpty) {
      return '先去 设置 → AI 服务 填好对话模型的 API Key';
    }
    if (!await _rec.hasPermission()) {
      return '没有麦克风权限，无法通话';
    }
    _callAlive = true;
    _interrupted = false;
    _setPhase(CallPhase.listening, '在听，说完停一下就好');
    _callLoop();
    return null;
  }

  Future<void> hangUp() async {
    _callAlive = false;
    _interrupted = true;
    _cancel?.cancel();
    await tts.stopDirect();
    try {
      await _player.stop();
    } catch (_) {}
    _setPhase(CallPhase.off, '');
  }

  /// 打断：立刻闭嘴 + 丢弃没说完的句子，回到聆听。
  Future<void> interrupt() async {
    if (callPhase != CallPhase.speaking && callPhase != CallPhase.thinking) {
      return;
    }
    _interrupted = true;
    _cancel?.cancel();
    await tts.stopDirect();
    try {
      await _player.stop();
    } catch (_) {}
  }

  void _setPhase(CallPhase p, String hint) {
    callPhase = p;
    callHint = hint;
    notifyListeners();
  }

  Future<void> _callLoop() async {
    while (_callAlive) {
      _interrupted = false;
      _setPhase(CallPhase.listening, '在听，说完停一下就好');
      final audio = await _listenOnce();
      if (!_callAlive) break;
      if (audio == null) continue;

      _setPhase(CallPhase.thinking, '正在听懂你说的…');
      String heard;
      try {
        heard = await stt.transcribe(settings: settingsOf(), audio: audio);
      } catch (e) {
        _setPhase(CallPhase.listening, '识别失败：$e');
        continue;
      }
      if (heard.trim().isEmpty) continue;

      messages.add(CompanionMessage(role: 'user', text: heard.trim()));
      notifyListeners();
      await _speakReply();
      await _persist();
    }
    _setPhase(CallPhase.off, '');
  }

  /// 录一句话：振幅 VAD——开口后静音 1.3s 认为说完。返回 null 表示这轮
  /// 没录到有效人声（被打断/挂断/一直没说话超时兜底）。
  Future<File?> _listenOnce() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/companion_utt.wav';
    try {
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav, // wav 所有转写端点都认
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      _setPhase(CallPhase.listening, '录音启动失败：$e');
      await Future.delayed(const Duration(seconds: 2));
      return null;
    }

    final began = DateTime.now();
    var speechStarted = false;
    var lastLoud = began;
    var noiseFloor = -50.0;
    while (_callAlive && !_interrupted) {
      await Future.delayed(const Duration(milliseconds: 150));
      double db;
      try {
        db = (await _rec.getAmplitude()).current;
      } catch (_) {
        db = -160;
      }
      if (db.isNaN || db.isInfinite) db = -160;
      final now = DateTime.now();
      if (!speechStarted) {
        // 静音期跟踪本底噪声（EMA），说话判定 = 高出本底 12dB 且 > -38dBFS。
        if (db > -120) noiseFloor = noiseFloor * 0.9 + db * 0.1;
        if (db > math.max(noiseFloor + 12, -38)) {
          speechStarted = true;
          lastLoud = now;
        }
        // 90 秒没人说话：吐个提示，继续听（不挂断——可能在走路看风景）。
        if (now.difference(began).inSeconds > 90) {
          _setPhase(CallPhase.listening, '还在呢，想聊随时开口');
          break;
        }
      } else {
        if (db > math.max(noiseFloor + 8, -42)) lastLoud = now;
        if (now.difference(lastLoud).inMilliseconds > 1300) break; // 说完了
        if (now.difference(began).inSeconds > 30) break; // 单句上限
      }
    }

    String? stopped;
    try {
      stopped = await _rec.stop();
    } catch (_) {}
    if (!_callAlive || _interrupted || !speechStarted || stopped == null) {
      return null;
    }
    final f = File(stopped);
    return await f.exists() ? f : null;
  }

  /// LLM 流式生成 → 按句切分 → TTS 合成（预取一句）→ 顺序播放。
  Future<void> _speakReply() async {
    final reply =
        CompanionMessage(role: 'assistant', text: '', streaming: true);
    messages.add(reply);
    notifyListeners();

    final s = settingsOf();
    final queue = <String>[];
    var llmDone = false;
    var carry = '';
    _cancel = CancelToken();

    void flushCarry({bool force = false}) {
      // 句子边界切分；太长的（>80 字）也切，免得第一句迟迟不开播。
      while (true) {
        final idx = carry.indexOf(RegExp(r'[。！？!?；;\n]'));
        if (idx >= 0) {
          final sent = carry.substring(0, idx + 1).trim();
          carry = carry.substring(idx + 1);
          if (_speakable(sent).isNotEmpty) queue.add(sent);
        } else if (carry.length > 80) {
          final cut = carry.lastIndexOf(RegExp(r'[，,、\s]'), 79);
          final at = cut > 20 ? cut + 1 : 80;
          final sent = carry.substring(0, at).trim();
          carry = carry.substring(at);
          if (_speakable(sent).isNotEmpty) queue.add(sent);
        } else {
          break;
        }
      }
      if (force && carry.trim().isNotEmpty) {
        if (_speakable(carry).isNotEmpty) queue.add(carry.trim());
        carry = '';
      }
    }

    final llm = () async {
      try {
        final msgs = await _llmMessages(voice: true);
        await for (final delta in ai.chatStream(
          settings: s,
          messages: msgs,
          temperature: 0.8,
          maxTokens: 320,
          timeout: const Duration(minutes: 2),
          cancelToken: _cancel,
        )) {
          reply.text += delta;
          carry += delta;
          flushCarry();
          notifyListeners();
        }
      } catch (e) {
        if (reply.text.isEmpty) {
          reply.error = true;
          reply.text = '出错了：$e';
          _setPhase(CallPhase.thinking, '模型出错：$e');
        }
      } finally {
        flushCarry(force: true);
        llmDone = true;
      }
    }();

    // 消费端。系统引擎自己出声（speak，逐句）；网络引擎合成 bytes 再播，
    // 且合成当前句时预取下一句，句间几乎无缝。所有等待都有硬超时——
    // 任何引擎悬挂（MIUI 回调丢失、网络黑洞）都不允许卡死通话循环。
    try {
      final selfPlaying = tts.playsItself(s);

      Future<Uint8List?> synth(String sent) async {
        try {
          return await tts
              .synthesize(settings: s, text: _speakable(sent))
              .timeout(const Duration(seconds: 25));
        } catch (e) {
          callHint = '语音合成失败：$e';
          notifyListeners();
          return null;
        }
      }

      Future<Uint8List?>? next;
      while (_callAlive && !_interrupted) {
        if (queue.isEmpty && next == null) {
          if (llmDone) break;
          await Future.delayed(const Duration(milliseconds: 60));
          continue;
        }
        if (selfPlaying) {
          final sent = queue.removeAt(0);
          _setPhase(CallPhase.speaking, '说话中，可随时打断');
          try {
            await tts
                .speakDirect(settings: s, text: _speakable(sent))
                .timeout(const Duration(seconds: 45));
          } catch (e) {
            callHint = '朗读失败：$e';
            notifyListeners();
          }
          continue;
        }
        final cur = next ?? synth(queue.removeAt(0));
        next = null;
        final bytes = await cur;
        if (!_callAlive || _interrupted) break;
        if (queue.isNotEmpty) next = synth(queue.removeAt(0));
        if (bytes == null || bytes.isEmpty) continue;
        _setPhase(CallPhase.speaking, '说话中，可随时打断');
        await _playBytes(bytes);
      }
    } finally {
      try {
        await llm.timeout(const Duration(seconds: 10));
      } catch (_) {}
      reply.streaming = false;
      if (reply.text.isEmpty && !reply.error) {
        messages.remove(reply);
      }
      notifyListeners();
    }
  }

  /// 去掉不适合朗读的符号（markdown 残留、代码引号）。
  static String _speakable(String s) => s
      .replaceAll(RegExp(r'[*#`>~_\[\]()]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> _playBytes(Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/companion_tts_${_ttsSeq++ % 4}.mp3');
      await f.writeAsBytes(bytes, flush: true);
      await _player.setFilePath(f.path);
      // play() 在播完 / 被 stop() 打断时都会返回。
      await _player.play().timeout(const Duration(minutes: 2));
      await _player.stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    _callAlive = false;
    _cancel?.cancel();
    _rec.dispose();
    _player.dispose();
    super.dispose();
  }
}
