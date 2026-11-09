package com.example.mnn

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "device_info")
            .setMethodCallHandler { call, result ->
                if (call.method != "get") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val activityManager =
                    getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val memoryInfo = ActivityManager.MemoryInfo()
                activityManager.getMemoryInfo(memoryInfo)

                val rawSoc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Build.SOC_MODEL
                } else {
                    Build.HARDWARE
                }
                val soc = if (rawSoc.isBlank() || rawSoc == "unknown") {
                    Build.HARDWARE
                } else {
                    rawSoc
                }

                result.success(
                    mapOf(
                        "model" to Build.MODEL,
                        "soc" to soc,
                        "board" to Build.BOARD,
                        "hardware" to Build.HARDWARE,
                        "android" to Build.VERSION.RELEASE,
                        "ramBytes" to memoryInfo.totalMem,
                        "cores" to Runtime.getRuntime().availableProcessors(),
                    ),
                )
            }
    }
}
