package com.bluelock.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the protection service after reboot so locks survive restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
            // Foreground-only unlock sessions do not survive a reboot: the
            // protected app is no longer in the foreground.
            LockPrefs.clearForegroundOnlySessions(context)
            LockPrefs.setLastForeground(context, null)
            LockPrefs.setLastPollTime(context, 0L)
            AppLockService.ensureRunning(context)
        }
    }
}
