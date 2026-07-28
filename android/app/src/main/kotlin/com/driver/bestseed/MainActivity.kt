package com.driver.bestseed

import android.content.Intent
import android.content.Context
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bestseeds/device_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getManufacturer" -> result.success(Build.MANUFACTURER)
                    "getBatteryLevel" -> {
                        val batteryManager =
                            getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val level = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                        result.success(level)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val powerManager =
                            getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(powerManager.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val powerManager =
                                    getSystemService(Context.POWER_SERVICE) as PowerManager
                                if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                                    val intent = Intent(
                                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                        Uri.parse("package:$packageName")
                                    ).apply {
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(intent)
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error(
                                "BATTERY_OPT_REQUEST_FAILED",
                                e.message,
                                null
                            )
                        }
                    }
                    "acquireWakeLock" -> {
                        result.success(WakeLockManager.acquire(applicationContext))
                    }
                    "releaseWakeLock" -> {
                        result.success(WakeLockManager.release())
                    }
                    "isWakeLockHeld" -> {
                        result.success(WakeLockManager.isHeld())
                    }
                    "isAggressiveOem" -> {
                        result.success(OemAutoStartHelper.isAggressive())
                    }
                    "openOemAutoStartSettings" -> {
                        result.success(OemAutoStartHelper.openAutoStartSettings(this))
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
