#!/usr/bin/env python3
"""EdgeTTS → OpenAI 兼容中转（单文件，部署到 NAS / 任意常驻小机器）。

为什么需要它：
  微软 Edge 朗读的免费端点 2026 起按客户端指纹放行——官方 python 库
  （edge-tts）能连，App 里的 Dart 网络栈同参数直接 403。所以把「免费」
  放到服务端：这里用 python edge-tts 出声，App 用「OpenAI 兼容」引擎
  指向本服务即可（设置 → AI 服务 → 语音合成 → OpenAI 兼容，
  Base URL 填 http://<NAS_IP>:8123/v1，voice 填 Edge 音色名）。

依赖与运行：
    pip install edge-tts          # 唯一依赖，社区维护、随微软指纹更新
    python3 edge_tts_proxy.py                      # 监听 0.0.0.0:8123
    EDGE_PROXY_TOKEN=secret python3 edge_tts_proxy.py   # 可选 Bearer 鉴权
    EDGE_PROXY_PORT=9000 python3 edge_tts_proxy.py      # 换端口

接口（OpenAI 兼容子集）：
    POST /v1/audio/speech
        {"input": "你好", "voice": "zh-CN-XiaoxiaoNeural", "speed": 1.0}
        → audio/mpeg 字节。model / response_format 字段接受但忽略（恒 mp3）。
    GET  /v1/voices?q=zh-        # 列出音色（调试用）

常用中文音色：zh-CN-XiaoxiaoNeural 晓晓 / zh-CN-XiaoyiNeural 晓伊 /
zh-CN-YunxiNeural 云希 / zh-CN-YunyangNeural 云扬 /
zh-TW-HsiaoChenNeural 台湾晓臻 / zh-HK-HiuMaanNeural 粤语晓曼。

systemd 部署示例（NAS）：
    [Unit]
    Description=EdgeTTS OpenAI-compatible proxy
    After=network-online.target
    [Service]
    Environment=EDGE_PROXY_TOKEN=changeme
    ExecStart=/usr/bin/python3 /opt/edge-tts-proxy/edge_tts_proxy.py
    Restart=always
    [Install]
    WantedBy=multi-user.target
"""

import asyncio
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import edge_tts
except ImportError:  # pragma: no cover
    raise SystemExit("缺依赖：pip install edge-tts")

TOKEN = os.environ.get("EDGE_PROXY_TOKEN", "")
PORT = int(os.environ.get("EDGE_PROXY_PORT", "8123"))
DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"


async def _synth(text: str, voice: str, speed: float) -> bytes:
    pct = round((speed - 1.0) * 100)
    rate = f"{'+' if pct >= 0 else ''}{pct}%"
    out = bytearray()
    async for chunk in edge_tts.Communicate(text, voice, rate=rate).stream():
        if chunk["type"] == "audio":
            out.extend(chunk["data"])
    return bytes(out)


async def _voices(q: str):
    all_v = await edge_tts.list_voices()
    return [
        {"name": v["ShortName"], "gender": v["Gender"], "locale": v["Locale"]}
        for v in all_v
        if q.lower() in v["ShortName"].lower()
    ]


class Handler(BaseHTTPRequestHandler):
    def _deny(self, code, msg):
        body = json.dumps({"error": {"message": msg}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_GET(self):
        if not self._authed():
            return self._deny(401, "bad token")
        if self.path.startswith("/v1/voices"):
            q = ""
            if "?q=" in self.path:
                q = self.path.split("?q=", 1)[1]
            data = json.dumps(asyncio.run(_voices(q)), ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self._deny(404, "not found")

    def do_POST(self):
        if not self._authed():
            return self._deny(401, "bad token")
        if not self.path.endswith("/audio/speech"):
            return self._deny(404, "not found")
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("input") or "").strip()
            if not text:
                return self._deny(400, "input is empty")
            voice = req.get("voice") or DEFAULT_VOICE
            speed = float(req.get("speed") or 1.0)
            audio = asyncio.run(_synth(text, voice, speed))
            if not audio:
                return self._deny(502, "edge-tts returned no audio")
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Content-Length", str(len(audio)))
            self.end_headers()
            self.wfile.write(audio)
        except Exception as e:  # noqa: BLE001 — 单文件服务，兜底成 502
            self._deny(502, f"edge-tts failed: {e}")

    def log_message(self, fmt, *args):  # 精简日志：一行一个请求
        print(f"[edge-proxy] {self.address_string()} {fmt % args}")


if __name__ == "__main__":
    print(f"EdgeTTS proxy on 0.0.0.0:{PORT}"
          f"{'（Bearer 鉴权已开）' if TOKEN else '（无鉴权，别暴露公网）'}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
