package com.example.bestseeds

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bestseeds/device_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "getManufacturer") {
                    result.success(Build.MANUFACTURER)
                } else {
                    result.notImplemented()
                }
            }
    }
}
