package com.bluelock.app

import android.content.Context
import android.os.SystemClock
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Process-wide pre-warmed FlutterEngine for [LockActivity].
 *
 * Booting a Flutter engine (AOT snapshot load, Dart isolate startup, plugin
 * registration) measured ~0.6s on an emulator and is the dominant stage of
 * the protected-app lock delay - on mid-range hardware it runs to multiple
 * seconds. This cache creates the engine once per process (when the
 * protection service starts), lets the Dart app boot on the idle "lock/"
 * route, and hands the same engine to whichever LockActivity instance is
 * currently showing. The protected package is pushed over the
 * "com.bluelock.app/lock" channel ("showLock"), so one engine serves any
 * protected app without rebooting.
 *
 * If the engine is missing (process just started, warm still in flight,
 * low-memory kill), LockActivity falls back to its original cold-boot
 * behaviour: a fresh engine with initial route "lock/<package>".
 */
object LockEngineCache {
    const val ENGINE_ID = "bluelock-lock"
    private const val TAG = "BlueLock"
    private const val LOCK_CHANNEL = "com.bluelock.app/lock"

    @Volatile
    private var engine: FlutterEngine? = null

    /** LockActivity currently attached to the cached engine, if any. */
    @Volatile
    var currentActivity: WeakReference<LockActivity>? = null
        internal set

    val isReady: Boolean
        get() = engine != null

    /** Engine id for FlutterActivity's cached-engine attach, or null. */
    fun engineIdOrNull(): String? = if (engine != null) ENGINE_ID else null

    /**
     * Creates the cached engine. Must run on the main thread; idempotent.
     * Called once when [AppLockService] starts (protection became active).
     */
    fun warm(context: Context) {
        if (engine != null) return
        val t0 = SystemClock.elapsedRealtime()
        val appContext = context.applicationContext
        val e = FlutterEngine(appContext)
        e.navigationChannel.setInitialRoute("lock/")
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "main"
            )
        )
        NativeBridge.register(appContext, e)
        registerLockChannel(appContext, e)
        FlutterEngineCache.getInstance().put(ENGINE_ID, e)
        engine = e
        Log.i(
            TAG,
            "PERF: cached lock engine warmed in ${SystemClock.elapsedRealtime() - t0}ms"
        )
    }

    /**
     * Pushes the protected package (and optional conversation username) to
     * the Dart lock host so it replaces the idle placeholder. Fire-and-forget:
     * on the warm path the Dart handler was registered during the engine's
     * boot, long before any attach.
     */
    fun showLock(packageName: String, chatUsername: String? = null) {
        val e = engine ?: return
        val target = if (chatUsername.isNullOrBlank()) {
            packageName
        } else {
            mapOf("package" to packageName, "chat" to chatUsername)
        }
        try {
            MethodChannel(e.dartExecutor.binaryMessenger, LOCK_CHANNEL)
                .invokeMethod("showLock", target)
        } catch (t: Throwable) {
            // The engine can be mid-teardown after a low-memory kill; never
            // let a best-effort push crash the lock activity.
            Log.w(TAG, "showLock push failed for $packageName", t)
        }
    }

    /** Resets the Dart lock host to its idle placeholder. Best-effort. */
    fun clearLock() {
        val e = engine ?: return
        try {
            MethodChannel(e.dartExecutor.binaryMessenger, LOCK_CHANNEL)
                .invokeMethod("clearLock", null)
        } catch (_: Exception) {
        }
    }

    private fun registerLockChannel(context: Context, e: FlutterEngine) {
        MethodChannel(e.dartExecutor.binaryMessenger, LOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                val activity = currentActivity?.get()
                when (call.method) {
                    "unlock" -> {
                        val ok = LockActivity.applyUnlock(
                            context,
                            call.arguments,
                            activity?.lockedPackage,
                            activity?.lockedChat
                        )
                        if (ok) {
                            result.success(null)
                            activity?.finish()
                        } else {
                            result.error("bad_args", "target required", null)
                        }
                    }
                    // No unauthenticated reset method: recovery is verified
                    // in Dart before it may replace the credential.
                    "getBiometricStatus" ->
                        result.success(BiometricAuth.status(context))
                    "authenticateBiometric" -> {
                        if (activity == null) {
                            Log.w(
                                TAG,
                                "authenticateBiometric refused: no attached " +
                                    "lock activity persistent=true"
                            )
                            result.error(
                                "unavailable",
                                "Lock activity not attached",
                                null
                            )
                        } else {
                            authenticate(activity, call.arguments, result)
                        }
                    }
                    "markUsable" -> {
                        val fromTrigger = activity?.launchTimeFromTrigger()
                        if (fromTrigger != null && fromTrigger >= 0) {
                            Log.i(
                                TAG,
                                "PERF: First usable lock screen UI reached " +
                                    "in ${fromTrigger}ms from launch"
                            )
                        } else {
                            Log.i(TAG, "PERF: First usable lock screen UI reached")
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("UNCHECKED_CAST")
    private fun authenticate(
        activity: LockActivity,
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        val pkg = activity.lockedPackage
        if (pkg == null) {
            result.error("bad_args", "package required", null)
            return
        }
        val args = arguments as? Map<*, *>
        val label = args?.get("label") as? String ?: pkg
        when (
            BiometricAuth.start(
                activity = activity,
                title = "Blue Lock",
                subtitle = "Authenticate to open $label"
            ) { outcome, detail -> BiometricAuth.reply(result, outcome, detail) }
        ) {
            BiometricAuth.Start.READY ->
                Log.d(TAG, "launching system biometric prompt for $pkg (cached engine)")
            BiometricAuth.Start.BUSY ->
                result.error("busy", "Biometric prompt already showing", null)
            BiometricAuth.Start.HOST_NOT_READY ->
                result.error("unavailable", "Lock screen not active", null)
            BiometricAuth.Start.NO_BIOMETRICS ->
                result.error("unavailable", "No enrolled biometrics", null)
        }
    }
}
