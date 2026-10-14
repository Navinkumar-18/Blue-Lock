package com.bluelock.app

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Full-screen activity hosted over a protected app. Shows the existing
 * Flutter lock screen (app icon, name, PIN keypad, optional biometrics).
 * Finishes when the user authenticates or leaves the protected app.
 *
 * Two engine paths:
 *  - Warm: attaches the process-wide pre-warmed engine from
 *    [LockEngineCache] (see there). The engine is already booted; the
 *    protected package is pushed over the lock channel and the PIN screen
 *    replaces the idle placeholder. This removes the multi-hundred-ms to
 *    multi-second engine cold start from the authentication path.
 *  - Cold (cache empty): boots a fresh engine with initial route
 *    "lock/<package>" - the original behaviour, kept as a correct fallback.
 *
 * Extends [FlutterFragmentActivity] so androidx [BiometricPrompt] can attach
 * to this activity.
 */
class LockActivity : FlutterFragmentActivity() {

    @Volatile
    var lockedPackage: String? = null
        private set

    private var biometricPrompt: androidx.biometric.BiometricPrompt? = null
    private var biometricActive = false
    private val mainHandler = Handler(Looper.getMainLooper())

    /** elapsedRealtime of the service's launch trigger, if provided. */
    private var launchTriggerTime = 0L

    /** Milliseconds from the service trigger to now, or -1 if unknown. */
    fun launchTimeFromTrigger(): Long =
        if (launchTriggerTime > 0) SystemClock.elapsedRealtime() - launchTriggerTime
        else -1

    /**
     * Non-null only while [LockEngineCache] holds a warmed engine: the
     * embedding then attaches that engine instead of creating a new one and
     * ignores [getInitialRoute] (the engine is already running the idle
     * "lock/" route; the package arrives via the lock channel).
     */
    override fun getCachedEngineId(): String? = LockEngineCache.engineIdOrNull()

    override fun getInitialRoute(): String {
        val pkg = intent.getStringExtra(EXTRA_PACKAGE) ?: ""
        // Deliberately WITHOUT a leading slash: a "/lock/<pkg>" initial route
        // makes Navigator.defaultGenerateInitialRoutes split the name into
        // segments and also materialise "/" and "/lock" routes underneath the
        // lock screen. The Dart router in lib/app.dart matches "lock/<pkg>".
        return "lock/$pkg"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val t0 = SystemClock.elapsedRealtime()
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        launchTriggerTime = intent.getLongExtra(EXTRA_LAUNCH_TIME, 0L)
        lockedPackage = intent.getStringExtra(EXTRA_PACKAGE)
        isShowing = true
        showingPackage = lockedPackage
        launchPendingSince = 0L
        LockEngineCache.currentActivity = WeakReference(this)
        val cached = LockEngineCache.isReady
        Log.d(
            TAG,
            "onCreate: showing lock screen for $lockedPackage (cachedEngine=$cached)"
        )
        super.onCreate(savedInstanceState)
        if (cached) {
            // Warm path: the Dart lock host is already running on the cached
            // engine - push the protected package so the PIN screen replaces
            // the idle placeholder. Handler registered at warm time.
            lockedPackage?.let { LockEngineCache.showLock(it) }
        }
        Log.i(
            TAG,
            "PERF: LockActivity.onCreate done: ${SystemClock.elapsedRealtime() - t0}ms" +
                " (total from service: ${launchTimeFromTrigger()}ms)"
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val pkg = intent.getStringExtra(EXTRA_PACKAGE)
        Log.d(TAG, "onNewIntent: pkg=$pkg current=$lockedPackage")
        if (pkg != null && pkg != lockedPackage) {
            lockedPackage = pkg
            showingPackage = pkg
            if (LockEngineCache.isReady) {
                // Retarget the running lock host without rebooting an engine.
                LockEngineCache.showLock(pkg)
            } else {
                // Cold engine: rebuild so the fresh boot uses the new route.
                recreate()
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && launchTriggerTime > 0) {
            Log.i(
                TAG,
                "PERF: LockActivity window focused at ${launchTimeFromTrigger()}ms from service trigger"
            )
        }
    }

    override fun onDestroy() {
        isShowing = false
        showingPackage = null
        if (LockEngineCache.currentActivity?.get() === this) {
            LockEngineCache.currentActivity = null
            // Reset the cached engine's Dart host to its idle placeholder so
            // the next protected app starts from a clean lock screen.
            if (LockEngineCache.isReady) {
                LockEngineCache.clearLock()
            }
        }
        Log.d(TAG, "onDestroy: lockedPackage=$lockedPackage")
        super.onDestroy()
    }

    override fun onStop() {
        super.onStop()
        // The user left the protected app (home / recents) - dismiss the lock
        // screen; the session was never granted. Stay alive while the system
        // biometric prompt is on screen (own prompt on the cold path, the
        // cached engine's prompt on the warm path).
        if (!biometricActive && !LockEngineCache.isBiometricActive) {
            Log.d(TAG, "onStop without active biometric - finishing")
            finish()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (LockEngineCache.isReady) {
            // Cached engine: NativeBridge and the lock channel were registered
            // once when the engine was warmed - do not re-register.
            Log.d(TAG, "configureFlutterEngine: cached engine - skipping registration")
            return
        }
        super.configureFlutterEngine(flutterEngine)
        NativeBridge.register(this, flutterEngine)

        val appContext = applicationContext
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.bluelock.app/lock"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "unlock" -> {
                    val pkg = (call.arguments as? String) ?: lockedPackage
                    if (pkg == null) {
                        result.error("bad_args", "package required", null)
                    } else {
                        Log.d(TAG, "unlock accepted for $pkg - dismissing lock")
                        LockPrefs.unlock(
                            appContext,
                            pkg,
                            LockPrefs.relockTimeout(appContext)
                        )
                        result.success(null)
                        mainHandler.post { finish() }
                    }
                }
                "resetProtection" -> {
                    Log.d(TAG, "resetProtection requested - wiping and finishing")
                    LockPrefs.resetAll(appContext)
                    AppLockService.stop(appContext)
                    result.success(null)
                    mainHandler.post { finish() }
                }
                "getBiometricStatus" -> {
                    result.success(BiometricAuth.status(appContext))
                }
                "authenticateBiometric" ->
                    authenticateBiometric(call.arguments, result)
                "markUsable" -> {
                    val total = launchTimeFromTrigger()
                    if (total >= 0) {
                        Log.i(
                            TAG,
                            "PERF: First usable lock screen UI reached in ${total}ms from launch"
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
    private fun authenticateBiometric(
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        val pkg = lockedPackage
        if (pkg == null) {
            result.error("bad_args", "package required", null)
            return
        }
        if (biometricActive) {
            result.error("busy", "Biometric prompt already showing", null)
            return
        }
        if (!BiometricAuth.canAuthenticate(this)) {
            Log.d(TAG, "authenticateBiometric: no enrolled biometrics")
            result.error("unavailable", "No enrolled biometrics", null)
            return
        }
        val args = arguments as? Map<*, *>
        val label = args?.get("label") as? String ?: pkg
        biometricActive = true
        Log.d(TAG, "launching system biometric prompt for $pkg")
        biometricPrompt = BiometricAuth.showPrompt(
            activity = this,
            title = "Blue Lock",
            subtitle = "Authenticate to open $label"
        ) { outcome, detail ->
            biometricActive = false
            biometricPrompt = null
            Log.d(TAG, "biometric outcome=$outcome for $pkg")
            when {
                outcome == "success" -> result.success(true)
                outcome == "user_cancel" ->
                    result.error("user_cancel", detail, null)
                else -> result.error("auth_failed", detail, null)
            }
        }
    }

    companion object {
        const val EXTRA_PACKAGE = "package"
        const val EXTRA_LAUNCH_TIME = "launch_time"
        private const val TAG = "BlueLock"

        @Volatile
        var isShowing: Boolean = false
            private set

        /** Package the current lock instance is guarding, if any. */
        @Volatile
        var showingPackage: String? = null
            private set

        /**
         * elapsedRealtime when the service last requested a lock launch and
         * the activity had not yet come up. Cleared in onCreate; lets the
         * service suppress duplicate startActivity calls in the gap between
         * the request and the activity's first on-screen frame.
         */
        @Volatile
        var launchPendingSince: Long = 0L
    }
}
