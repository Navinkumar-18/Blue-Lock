package com.bluelock.app

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Method channel between Flutter and native Android:
 * installed-app discovery, permission state, lock configuration and
 * foreground detection. Also hosts the self-authentication session and the
 * AndroidX biometric prompt used when Blue Lock locks itself.
 */
object NativeBridge {
    private const val CHANNEL = "com.bluelock.app/native"
    private const val TAG = "BlueLock"
    private const val REQUEST_NOTIFICATIONS = 51002

    /** Replies to the method channel on the platform thread, as required. */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Installed-app discovery (package queries + icon bitmap/PNG encoding for
     * every app) runs here instead of on the Android main thread, so the
     * platform thread stays free for input, rendering and platform messages
     * while a large app list is being collected.
     */
    private val ioExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "bluelock-io").apply { isDaemon = true }
        }

    /**
     * Registers the native channel on [flutterEngine].
     *
     * [context] may be an activity (dashboard / cold-lock engines - enables
     * the self-auth biometric prompt, which must attach to a
     * [FragmentActivity]) or a plain application context (the pre-warmed
     * cached lock engine, created before any activity exists). Biometric
     * calls on a context-only registration report "unavailable"; the lock
     * screen's own biometrics go through the separate lock channel and are
     * unaffected.
     */
    fun register(context: Context, flutterEngine: FlutterEngine) {
        val appContext = context.applicationContext
        val activity = context as? FragmentActivity
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    handle(activity, appContext, call.method, call.arguments, result)
                } catch (e: Exception) {
                    result.error("native_error", e.message, null)
                }
            }
    }

    @Suppress("UNCHECKED_CAST")
    private fun handle(
        activity: FragmentActivity?,
        context: Context,
        method: String,
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        when (method) {
            "getInstalledApps" -> {
                val t0 = SystemClock.elapsedRealtime()
                ioExecutor.execute {
                    try {
                        val apps = getInstalledApps(context)
                        Log.d(
                            TAG,
                            "getInstalledApps: ${apps.size} apps in " +
                                "${SystemClock.elapsedRealtime() - t0}ms " +
                                "on ${Thread.currentThread().name}"
                        )
                        mainHandler.post { result.success(apps) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("native_error", e.message, null) }
                    }
                }
            }
            "getAppInfo" -> {
                val pkg = arguments as? String
                if (pkg == null) {
                    result.error("bad_args", "package name required", null)
                } else {
                    result.success(getAppInfo(context, pkg))
                }
            }
            "hasUsageAccess" -> result.success(hasUsageAccess(context))
            "openUsageAccessSettings" -> {
                openUsageAccessSettings(context)
                result.success(null)
            }
            "hasNotificationPermission" -> result.success(
                hasNotificationPermission(context)
            )
            "requestNotificationPermission" -> {
                requestNotificationPermission(activity, context, result)
            }
            "isIgnoringBatteryOptimizations" -> result.success(
                isIgnoringBatteryOptimizations(context)
            )
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBatteryOptimizations(context)
                result.success(null)
            }
            "openBatteryOptimizationSettings" -> {
                openBatteryOptimizationSettings(context)
                result.success(null)
            }
            "openAppSettings" -> {
                openAppSettings(context)
                result.success(null)
            }
            "isProtectionServiceRunning" -> result.success(
                AppLockService.isRunning
            )
            "hasOverlayPermission" -> result.success(
                Settings.canDrawOverlays(context)
            )
            "openOverlaySettings" -> {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${context.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                result.success(null)
            }
            "setProtectedPackages" -> {
                val list = (arguments as? List<*>)?.filterIsInstance<String>()
                    ?: emptyList()
                val previous = LockPrefs.protectedPackages(context)
                LockPrefs.setProtectedPackages(context, list.toSet())
                // Drop unlock sessions for apps that are no longer protected.
                for (pkg in previous) {
                    if (pkg !in list) LockPrefs.clearSession(context, pkg)
                }
                AppLockService.ensureRunning(context)
                result.success(null)
            }
            "setLockEnabled" -> {
                LockPrefs.setLockEnabled(context, arguments == true)
                if (arguments == true) {
                    AppLockService.ensureRunning(context)
                } else {
                    AppLockService.stop(context)
                    LockPrefs.clearAllSessions(context)
                }
                result.success(null)
            }
            "setRelockTimeout" -> {
                val timeout = (arguments as? Int) ?: 0
                if (timeout != LockPrefs.relockTimeout(context)) {
                    // Policy changed: a session granted under the previous
                    // policy must not be honoured under the new one.
                    LockPrefs.clearSelfSession(context)
                }
                LockPrefs.setRelockTimeout(context, timeout)
                result.success(null)
            }
            "lockPackage" -> {
                val pkg = arguments as? String
                if (pkg != null) LockPrefs.clearSession(context, pkg)
                result.success(null)
            }
            "unlockPackage" -> {
                val pkg = arguments as? String
                if (pkg == null) {
                    result.error("bad_args", "package name required", null)
                } else {
                    LockPrefs.unlock(
                        context,
                        pkg,
                        LockPrefs.relockTimeout(context)
                    )
                    result.success(null)
                }
            }
            "isPackageUnlocked" -> {
                val pkg = arguments as? String
                result.success(
                    pkg != null && LockPrefs.isUnlocked(context, pkg)
                )
            }
            "getForegroundPackage" ->
                result.success(ForegroundDetector.currentPackage(context))
            "getBiometricStatus" -> result.success(BiometricAuth.status(context))
            "setBiometricEnabled" -> {
                LockPrefs.setBiometricEnabled(context, arguments == true)
                result.success(null)
            }
            // ---- Blue Lock self-authentication (app-entry gate) ----
            "isSelfUnlocked" -> result.success(LockPrefs.isSelfUnlocked(context))
            "unlockSelf" -> {
                LockPrefs.unlockSelf(context)
                result.success(null)
            }
            "lockSelf" -> {
                LockPrefs.clearSelfSession(context)
                result.success(null)
            }
            "selfBackgrounded" -> {
                LockPrefs.onSelfBackgrounded(context)
                result.success(null)
            }
            "authenticateBiometric" ->
                authenticateBiometric(activity, context, arguments, result)
            else -> result.notImplemented()
        }
    }

    /**
     * AndroidX [androidx.biometric.BiometricPrompt] for Blue Lock's own
     * authentication gate. Only a platform-reported success resolves the
     * pending result as success; cancellation and failure surface as errors
     * so the Flutter side keeps the PIN keypad as the fallback.
     */
    @Suppress("UNCHECKED_CAST")
    private fun authenticateBiometric(
        activity: FragmentActivity?,
        context: Context,
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        if (activity == null) {
            // Registered against a plain application context (cached lock
            // engine): no FragmentActivity to attach the system prompt to.
            Log.w(
                TAG,
                "self biometric refused: no host activity persistent=true"
            )
            result.error("unavailable", "No host activity for biometric prompt", null)
            return
        }
        val args = arguments as? Map<*, *>
        val label = args?.get("label") as? String ?: context.packageName
        when (
            BiometricAuth.start(
                activity = activity,
                title = "Blue Lock",
                subtitle = "Authenticate to open $label"
            ) { outcome, detail ->
                when {
                    outcome == "success" -> result.success(true)
                    outcome == "user_cancel" ->
                        result.error("user_cancel", detail, null)
                    else -> result.error("auth_failed", detail, null)
                }
            }
        ) {
            BiometricAuth.Start.READY -> Unit // reply arrives from the session
            BiometricAuth.Start.BUSY ->
                result.error("busy", "Biometric prompt already showing", null)
            BiometricAuth.Start.HOST_NOT_READY ->
                result.error("unavailable", "App entry gate not active", null)
            BiometricAuth.Start.NO_BIOMETRICS ->
                result.error("unavailable", "No enrolled biometrics", null)
        }
    }

    private fun getInstalledApps(context: Context): List<Map<String, Any?>> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = pm.queryIntentActivities(intent, PackageManager.MATCH_ALL)
        val seen = LinkedHashSet<String>()
        for (info in resolved) {
            seen.add(info.activityInfo.packageName)
        }
        val apps = ArrayList<Map<String, Any?>>()
        for (pkg in seen) {
            if (pkg == context.packageName) continue
            val map = appToMap(context, pkg) ?: continue
            apps.add(map)
        }
        apps.sortBy { (it["label"] as? String)?.lowercase() ?: "" }
        return apps
    }

    private fun getAppInfo(context: Context, pkg: String): Map<String, Any?>? =
        appToMap(context, pkg)

    private fun appToMap(context: Context, pkg: String): Map<String, Any?>? {
        val pm = context.packageManager
        return try {
            val info = pm.getPackageInfo(pkg, 0)
            val appInfo = info.applicationInfo ?: return null
            val label = pm.getApplicationLabel(appInfo).toString()
            val icon = iconToBytes(pm.getApplicationIcon(appInfo))
            val isSystem =
                (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            mapOf(
                "package" to pkg,
                "label" to label,
                "icon" to icon,
                "isSystem" to isSystem
            )
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        val size = 128
        val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else size
        val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else size
        val scale = size.toFloat() / maxOf(width, height)
        val w = (width * scale).toInt().coerceAtLeast(1)
        val h = (height * scale).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }

    /**
     * PNG-encodes the launcher icon to raw bytes. Raw byte arrays travel
     * over the standard codec untouched - unlike Base64 text they add no
     * 33% payload overhead and need no decode pass on the Dart side.
     */
    private fun iconToBytes(drawable: Drawable): ByteArray {
        val bitmap = drawableToBitmap(drawable)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        bitmap.recycle()
        return stream.toByteArray()
    }

    /**
     * Usage Access via AppOps. `internal` so [AppLockService] can re-verify
     * it periodically and detect revocation without a Flutter round trip.
     */
    internal fun hasUsageAccess(context: Context): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun openUsageAccessSettings(context: Context) {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    // ---- notification permission (Android 13+) ----

    /**
     * POST_NOTIFICATIONS gates visibility of the protection notification on
     * Android 13+. Without it the service still runs, but the user has no
     * signal that protection is active - and some OEMs treat FGS apps
     * without visible notifications more aggressively.
     */
    fun hasNotificationPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestNotificationPermission(
        activity: FragmentActivity?,
        context: Context,
        result: MethodChannel.Result
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true) // not required below Android 13
            return
        }
        if (hasNotificationPermission(context)) {
            result.success(true)
            return
        }
        if (activity == null) {
            result.error("unavailable", "No host activity to request permission", null)
            return
        }
        activity.requestPermissions(
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS
        )
        result.success(false) // actual grant is re-checked on next resume
    }

    // ---- battery optimization ----

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Opens the system dialog asking the user to exempt Blue Lock from
     * battery optimization. Justified: continuous foreground-app detection
     * is the app's core function and is throttled/killed under optimization
     * on most OEMs. The user always confirms in the system dialog - the
     * setting is never changed silently.
     */
    private fun requestIgnoreBatteryOptimizations(context: Context) {
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "battery-opt dialog unavailable, falling back to settings list")
            openBatteryOptimizationSettings(context)
        }
    }

    private fun openBatteryOptimizationSettings(context: Context) {
        val intent = try {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        } catch (e: Exception) {
            // Some OEM builds drop this action; app details is the fallback.
            appDetailsIntent(context)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "could not open battery settings", e)
            openAppSettings(context)
        }
    }

    /** App-details page: where Motorola exposes "Battery usage -> Unrestricted". */
    private fun openAppSettings(context: Context) {
        val intent = appDetailsIntent(context)
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "could not open app settings", e)
        }
    }

    private fun appDetailsIntent(context: Context): Intent =
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}
