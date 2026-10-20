package com.bluelock.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Restarts the protection service after reboot and after app replacement
 * (system update / `adb install -r`) so locks survive both.
 *
 * Both actions historically only handled BOOT_COMPLETED: an app update kills
 * the process and Android does not restart foreground services afterwards,
 * so protection silently stayed off until the user opened Blue Lock again.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.i(TAG, "recovery broadcast ${intent.action}: restarting protection service")
                // Foreground-only unlock sessions do not survive a reboot or
                // an app replacement: the protected app is no longer in the
                // foreground.
                LockPrefs.clearForegroundOnlySessions(context)
                LockPrefs.setLastForeground(context, null)
                LockPrefs.setLastPollTime(context, 0L)
                val started = AppLockService.ensureRunning(context)
                // Keep the watchdog chain alive even if this start failed
                // (e.g. background-start restrictions): the watchdog retries
                // with its own allowlist window.
                if (started) ServiceWatchdogReceiver.schedule(context)
            }
        }
    }

    companion object {
        private const val TAG = "BlueLock"
    }
}
