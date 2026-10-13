package com.bluelock.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativeBridge.register(this, flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        // Keep the protection service alive while the user interacts with us.
        AppLockService.ensureRunning(applicationContext)
    }
}
