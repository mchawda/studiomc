package com.studiomc.studiomc_app

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** llama.cpp host. `probe` is live; generation waits for the native lib. */
object MobileInferenceHost {
    const val METHOD_CHANNEL = "studiomc.mobile_inference"
    const val TOKEN_CHANNEL = "studiomc.mobile_inference/tokens"
    const val NOT_LINKED = "llama_cpp_not_linked"

    fun register(messenger: BinaryMessenger, context: Context) {
        EventChannel(messenger, TOKEN_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {}
                override fun onCancel(arguments: Any?) {}
            },
        )
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> result.success(probe(context))
                "load", "unload", "complete", "streamStart", "streamCancel", "embed" ->
                    result.error(
                        NOT_LINKED,
                        "llama.cpp is not linked yet. Place a GGUF under app support models/<id>/ and implement ${call.method} in MobileInferenceHost.",
                        call.method,
                    )
                else -> result.notImplemented()
            }
        }
    }

    fun probe(context: Context): Map<String, Any?> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mem)
        val smallest = context.resources.configuration.smallestScreenWidthDp
        val deviceClass = if (smallest >= 600) "tablet" else "phone"
        val accels = mutableListOf("cpu", "gpu")
        if (Build.VERSION.SDK_INT >= 27) {
            accels.add("nnapi")
        }
        return mapOf(
            "ramBytes" to mem.totalMem,
            "deviceClass" to deviceClass,
            "accelerators" to accels,
            "chipName" to Build.HARDWARE,
        )
    }
}
