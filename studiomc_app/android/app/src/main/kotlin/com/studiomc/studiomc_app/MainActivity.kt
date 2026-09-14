package com.studiomc.studiomc_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MobileInferenceHost.register(flutterEngine.dartExecutor.binaryMessenger, this)
    }
}
