package com.bluelock.app

import android.os.Bundle
import android.view.WindowManager
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Hosts the Blue Lock dashboard. Extends [FlutterFragmentActivity] (instead
 * of FlutterActivity) so the AndroidX [androidx.biometric.BiometricPrompt]
 * used by the self-authentication gate can attach to this activity, exactly
 * like [LockActivity] does for protected applications.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativeBridge.register(this, flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        // Keep the protection service alive while the user interacts with us.
        AppLockService.ensureRunning(applicationContext)
    }

    override fun onDestroy() {
        // Release a self-auth biometric session this activity owns; AndroidX
        // drops its callback on host destroy and would otherwise leave the
        // process-wide prompt latch stuck for the next attempt.
        BiometricAuth.abandon(this, "MainActivity destroyed")
        super.onDestroy()
    }
}
