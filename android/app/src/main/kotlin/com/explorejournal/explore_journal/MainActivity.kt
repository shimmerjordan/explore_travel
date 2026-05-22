package com.explorejournal.explore_journal

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Adds a single platform channel: `explorejournal/multicast_lock`.
 *
 * Why this exists: by default the Android Wi-Fi driver silently drops
 * incoming multicast packets to save power. Our group-discovery datagrams
 * therefore never reach `RawDatagramSocket` on un-rooted phones (some
 * vendor-modified ROMs and rooted devices override the default and seem to
 * "just work" — hence the symptom of one phone seeing the other but not
 * vice versa). Acquiring a `MulticastLock` re-enables multicast reception
 * for as long as it's held.
 */
class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "explorejournal/multicast_lock"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    if (lock == null) {
                        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        lock = wm.createMulticastLock("explore_journal_group").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    } else if (lock?.isHeld == false) {
                        lock?.acquire()
                    }
                    result.success(lock?.isHeld == true)
                }
                "release" -> {
                    if (lock?.isHeld == true) lock?.release()
                    result.success(true)
                }
                "status" -> result.success(lock?.isHeld == true)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try { if (lock?.isHeld == true) lock?.release() } catch (_: Throwable) {}
        super.onDestroy()
    }
}
