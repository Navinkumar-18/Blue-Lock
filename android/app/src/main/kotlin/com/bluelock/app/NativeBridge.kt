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
import android.os.Process
import android.provider.Settings
import android.util.Base64
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Method channel between Flutter and native Android:
 * installed-app discovery, permission state, lock configuration and
 * foreground detection. Also hosts the self-authentication session and the
 * AndroidX biometric prompt used when Blue Lock locks itself.
 */
object NativeBridge {
    private const val CHANNEL = "com.bluelock.app/native"

    /** One system biometric prompt at a time across the process. */
    @Volatile
    private var biometricActive = false

    fun register(activity: FragmentActivity, flutterEngine: FlutterEngine) {
        val appContext = activity.applicationContext
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
        activity: FragmentActivity,
        context: Context,
        method: String,
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        when (method) {
            "getInstalledApps" -> result.success(getInstalledApps(context))
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
        activity: FragmentActivity,
        context: Context,
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        if (biometricActive) {
            result.error("busy", "Biometric prompt already showing", null)
            return
        }
        if (!BiometricAuth.canAuthenticate(context)) {
            result.error("unavailable", "No enrolled biometrics", null)
            return
        }
        val args = arguments as? Map<*, *>
        val label = args?.get("label") as? String ?: context.packageName
        biometricActive = true
        BiometricAuth.showPrompt(
            activity = activity,
            title = "Blue Lock",
            subtitle = "Authenticate to open $label"
        ) { outcome, detail ->
            biometricActive = false
            when {
                outcome == "success" -> result.success(true)
                outcome == "user_cancel" ->
                    result.error("user_cancel", detail, null)
                else -> result.error("auth_failed", detail, null)
            }
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
            val icon = iconToBase64(pm.getApplicationIcon(appInfo))
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

    private fun iconToBase64(drawable: Drawable): String {
        val bitmap = drawableToBitmap(drawable)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        val bytes = stream.toByteArray()
        bitmap.recycle()
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    private fun hasUsageAccess(context: Context): Boolean {
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
}
