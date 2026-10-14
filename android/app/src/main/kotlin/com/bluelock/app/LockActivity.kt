package com.bluelock.app

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Full-screen activity hosted over a protected app. Boots a Flutter engine
 * with initial route "lock/<package>", which renders the existing Flutter
 * lock screen (app icon, name, PIN keypad, optional biometrics). Finishes
 * when the user authenticates or leaves the protected app.
 *
 * Extends [FlutterFragmentActivity] so androidx [BiometricPrompt] can attach
 * to this activity.
 */
class LockActivity : FlutterFragmentActivity() {

    private var lockedPackage: String? = null
    private var biometricPrompt: androidx.biometric.BiometricPrompt? = null
    private var biometricActive = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun getInitialRoute(): String {
        val pkg = intent.getStringExtra(EXTRA_PACKAGE) ?: ""
        // Deliberately WITHOUT a leading slash: a "/lock/<pkg>" initial route
        // makes Navigator.defaultGenerateInitialRoutes split the name into
        // segments and also materialise "/" and "/lock" routes underneath the
        // lock screen. The Dart router in lib/app.dart matches "lock/<pkg>".
        return "lock/$pkg"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val launchTime = intent.getLongExtra(EXTRA_LAUNCH_TIME, 0L)
        val t0 = SystemClock.elapsedRealtime()
        lockedPackage = intent.getStringExtra(EXTRA_PACKAGE)
        isShowing = true
        showingPackage = lockedPackage
        Log.d(TAG, "onCreate: showing lock screen for $lockedPackage")
        super.onCreate(savedInstanceState)
        val elapsedFromLaunch = if (launchTime > 0) SystemClock.elapsedRealtime() - launchTime else -1
        Log.i(TAG, "PERF: LockActivity.onCreate done: ${SystemClock.elapsedRealtime() - t0}ms (total from service: ${elapsedFromLaunch}ms)")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val pkg = intent.getStringExtra(EXTRA_PACKAGE)
        Log.d(TAG, "onNewIntent: pkg=$pkg current=$lockedPackage")
        if (pkg != null && pkg != lockedPackage) {
            // A different protected app came to the front: rebuild so the
            // engine boots with the lock/<new package> route.
            recreate()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        val launchTime = intent.getLongExtra(EXTRA_LAUNCH_TIME, 0L)
        if (hasFocus && launchTime > 0) {
            val total = SystemClock.elapsedRealtime() - launchTime
            Log.i(TAG, "PERF: LockActivity window focused at ${total}ms from service trigger")
        }
    }

    override fun onDestroy() {
        isShowing = false
        showingPackage = null
        Log.d(TAG, "onDestroy: lockedPackage=$lockedPackage")
        super.onDestroy()
    }

    override fun onStop() {
        super.onStop()
        // The user left the protected app (home / recents) - dismiss the lock
        // screen; the session was never granted. Stay alive while the system
        // biometric prompt is on screen.
        if (!biometricActive) {
            Log.d(TAG, "onStop without active biometric - finishing")
            finish()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
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
                    val launchTime = intent.getLongExtra(EXTRA_LAUNCH_TIME, 0L)
                    if (launchTime > 0) {
                        val total = SystemClock.elapsedRealtime() - launchTime
                        Log.i(TAG, "PERF: First usable lock screen UI reached in ${total}ms from launch")
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
    }
}
