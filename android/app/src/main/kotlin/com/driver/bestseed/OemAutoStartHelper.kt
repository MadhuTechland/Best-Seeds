package com.driver.bestseed

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * Deep-links to the OEM-specific "autostart" / "protected apps" / "background
 * apps" settings screen so the driver can whitelist Drive Bestseed on
 * aggressive Android ROMs.
 *
 * WHY: Xiaomi (MIUI), Vivo (Funtouch/OriginOS), Oppo (ColorOS), Realme (Realme
 * UI), OnePlus (OxygenOS newer), Honor/Huawei and Samsung all ship their own
 * battery managers that KILL foreground services even with a valid wake lock
 * and battery-optimization exemption. Google's Doze rules can be honoured
 * perfectly and the OEM's own service will still nuke us. The only fix on
 * these ROMs is the user explicitly enabling autostart / lock the app in the
 * OEM's "protected apps" list — this file gets the driver to that screen in
 * one tap.
 *
 * Each OEM tends to rename / move the activity every 1-2 major versions, so
 * we try a list of known component names for each manufacturer and fall back
 * to the standard app-info screen if none resolve.
 */
object OemAutoStartHelper {
    private const val TAG = "OemAutoStart"

    /**
     * Manufacturers whose stock battery manager reliably kills FGSes even
     * with a valid wake lock + battery-opt exemption. Used to decide whether
     * to nag the driver to open the autostart settings on journey start.
     */
    private val AGGRESSIVE_MANUFACTURERS = setOf(
        "xiaomi", "redmi", "poco",
        "vivo", "iqoo",
        "oppo", "realme",
        "oneplus",
        "honor", "huawei",
        "samsung",
        "asus",
        "meizu",
        "lenovo"
    )

    /** Known component names per manufacturer, tried in order. */
    private val COMPONENTS: Map<String, List<ComponentName>> = mapOf(
        // Xiaomi (MIUI) — POCO and Redmi run MIUI too
        "xiaomi" to listOf(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            ),
            ComponentName(
                "com.miui.powerkeeper",
                "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
            )
        ),

        // Vivo (Funtouch OS / OriginOS) — includes iQOO
        "vivo" to listOf(
            ComponentName(
                "com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"
            ),
            ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
            ),
            ComponentName(
                "com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"
            )
        ),

        // Oppo (ColorOS) and Realme (Realme UI, ColorOS-derived)
        "oppo" to listOf(
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity"
            ),
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.startupapp.StartupAppListActivity"
            ),
            ComponentName(
                "com.oppo.safe",
                "com.oppo.safe.permission.startup.StartupAppListActivity"
            )
        ),

        // OnePlus (OxygenOS newer versions)
        "oneplus" to listOf(
            ComponentName(
                "com.oneplus.security",
                "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
            )
        ),

        // Honor / Huawei
        "huawei" to listOf(
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.optimize.process.ProtectActivity"
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            )
        ),

        // Samsung
        "samsung" to listOf(
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.ui.battery.BatteryActivity"
            ),
            ComponentName(
                "com.samsung.android.sm",
                "com.samsung.android.sm.ui.battery.BatteryActivity"
            ),
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.battery.ui.BatteryActivity"
            )
        ),

        // Asus (ZenUI)
        "asus" to listOf(
            ComponentName(
                "com.asus.mobilemanager",
                "com.asus.mobilemanager.MainActivity"
            ),
            ComponentName(
                "com.asus.mobilemanager",
                "com.asus.mobilemanager.autostart.AutoStartActivity"
            )
        ),

        // Meizu (Flyme)
        "meizu" to listOf(
            ComponentName(
                "com.meizu.safe",
                "com.meizu.safe.security.SHOW_APPSEC"
            )
        ),

        // Lenovo
        "lenovo" to listOf(
            ComponentName(
                "com.lenovo.security",
                "com.lenovo.security.purebackground.PureBackgroundActivity"
            )
        )
    )

    /**
     * Alias table — some OEM brands share the same manager under a different
     * `Build.MANUFACTURER`. Map them to the canonical key in [COMPONENTS].
     */
    private val ALIASES = mapOf(
        "redmi" to "xiaomi",
        "poco" to "xiaomi",
        "iqoo" to "vivo",
        "realme" to "oppo",   // Realme UI = ColorOS fork
        "honor" to "huawei"
    )

    /** Normalise MANUFACTURER string. */
    private fun key(context: Context): String {
        val raw = Build.MANUFACTURER.lowercase().trim()
        return ALIASES[raw] ?: raw
    }

    fun isAggressive(): Boolean {
        val raw = Build.MANUFACTURER.lowercase().trim()
        return AGGRESSIVE_MANUFACTURERS.contains(raw) ||
            ALIASES.containsKey(raw)
    }

    /**
     * Try each known OEM activity in order; fall back to the standard app
     * info screen. Returns true if we launched *something* the user can
     * interact with, false only if nothing could be launched at all
     * (extremely unlikely — app info always resolves).
     */
    fun openAutoStartSettings(context: Context): Boolean {
        val brandKey = key(context)
        val components = COMPONENTS[brandKey] ?: emptyList()

        for (component in components) {
            try {
                val intent = Intent().apply {
                    this.component = component
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                // resolveActivity checks the intent can actually be handled
                // before we call startActivity — otherwise Android throws
                // ActivityNotFoundException on missing/renamed activities.
                if (intent.resolveActivity(context.packageManager) != null) {
                    context.startActivity(intent)
                    Log.i(TAG, "opened OEM autostart: ${component.flattenToShortString()}")
                    return true
                }
            } catch (e: Exception) {
                Log.w(TAG, "OEM autostart component failed: $component — $e")
            }
        }

        // Fallback — always resolvable
        return try {
            val fallback = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}")
            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            context.startActivity(fallback)
            Log.i(TAG, "opened app details as OEM autostart fallback")
            true
        } catch (e: Exception) {
            Log.e(TAG, "opening app details fallback failed", e)
            false
        }
    }
}
