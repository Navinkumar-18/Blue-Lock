package com.bluelock.app

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Full-screen activity hosted over a protected app. Shows the Flutter PIN
 * screen (initial route "lock/<package>") and finishes when the PIN is
 * verified or the user leaves.
 */
class LockActivity : FlutterActivity() {

    private var lockedPackage: String? = null

    override fun getInitialRoute(): String {
        val pkg = intent.getStringExtra(EXTRA_PACKAGE) ?: ""
        return "lock/$pkg"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        lockedPackage = intent.getStringExtra(EXTRA_PACKAGE)
        isShowing = true
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        isShowing = false
        super.onDestroy()
    }

    override fun onStop() {
        super.onStop()
        // User left the protected app (home, recents, etc.) - dismiss the
        // lock screen; the session was never granted.
        finish()
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
                        LockPrefs.unlock(
                            appContext,
                            pkg,
                            LockPrefs.relockTimeout(appContext)
                        )
                        result.success(null)
                        finish()
                    }
                }
                "resetProtection" -> {
                    LockPrefs.resetAll(appContext)
                    AppLockService.stop(appContext)
                    result.success(null)
                    finish()
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val EXTRA_PACKAGE = "package"

        @Volatile
        var isShowing: Boolean = false
            private set
    }
}
