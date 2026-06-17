package com.explorejournal.explore_journal

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Proxy

/**
 * Bridge to the embedded frpc gomobile library (`frpmobile.aar`).
 *
 * Deliberately reached via REFLECTION so this file compiles whether or not
 * the AAR is on the classpath. When the AAR is absent (e.g. a local checkout
 * without the gomobile build), method calls return a `frp_unavailable`
 * error, which the Dart side surfaces as [FrpUnsupported] — the rest of the
 * app builds and runs unchanged. When CI has built and bundled the AAR, the
 * same calls drive the real frpc.
 *
 * gomobile name mangling (target=android):
 *   Go `func New() *Engine`  → class `frpmobile.Frpmobile`, static `new_()`
 *   Go `*Engine` methods     → class `frpmobile.Engine` { start/reload/stop/running/setLogSink }
 *   Go `type LogSink interface{ Log(string) }` → Java interface `frpmobile.LogSink`
 */
object FrpBridge {
    private const val METHOD = "explorejournal/frp"
    private const val EVENTS = "explorejournal/frp_events"
    private const val ENGINE_FACTORY = "frpmobile.Frpmobile"
    private const val LOGSINK_IFACE = "frpmobile.LogSink"

    private var engine: Any? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(args: Any?) { sink = null }
            }
        )

        MethodChannel(messenger, METHOD).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        invokeStr(ensure(), "start", call.argument<String>("config") ?: "")
                        result.success(null)
                    }
                    "reload" -> {
                        invokeStr(ensure(), "reload", call.argument<String>("config") ?: "")
                        result.success(null)
                    }
                    "stop" -> {
                        engine?.let { it.javaClass.getMethod("stop").invoke(it) }
                        result.success(null)
                    }
                    "status" -> {
                        val e = engine
                        val running = e?.let { it.javaClass.getMethod("running").invoke(it) as? Boolean }
                        result.success(running ?: false)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: ClassNotFoundException) {
                result.error("frp_unavailable", "未内置 frpc（缺少 frpmobile.aar）", null)
            } catch (t: Throwable) {
                result.error("frp_error", t.cause?.message ?: t.message, null)
            }
        }
    }

    private fun invokeStr(target: Any, method: String, arg: String) {
        target.javaClass.getMethod(method, String::class.java).invoke(target, arg)
    }

    @Throws(ClassNotFoundException::class)
    private fun ensure(): Any {
        engine?.let { return it }
        val factory = Class.forName(ENGINE_FACTORY)
        val e = factory.getMethod("new_").invoke(null)
            ?: throw IllegalStateException("frpmobile.New() returned null")

        // Wire the Go LogSink reverse-interface to our EventChannel via a
        // dynamic proxy so we never reference the generated type at compile
        // time.
        try {
            val sinkIface = Class.forName(LOGSINK_IFACE)
            val proxy = Proxy.newProxyInstance(
                sinkIface.classLoader, arrayOf(sinkIface)
            ) { _, method, args ->
                if (method.name == "log" && args != null && args.isNotEmpty()) {
                    val line = args[0] as? String ?: ""
                    main.post { sink?.success(line) }
                }
                null
            }
            e.javaClass.getMethod("setLogSink", sinkIface).invoke(e, proxy)
        } catch (_: Throwable) {
            // Logging is best-effort; the engine still works without a sink.
        }
        engine = e
        return e
    }
}
