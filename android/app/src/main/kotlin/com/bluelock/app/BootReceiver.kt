package com.bluelock.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the protection service after reboot so locks survive restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
            AppLockService.ensureRunning(context)
        }
    }
}
