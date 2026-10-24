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
                ChatLockPrefs.clearForegroundOnlySessions(context)
                LockPrefs.setLastForeground(context, null)
                LockPrefs.setLastPollTime(context, 0L)
                if (LockPrefs.lockEnabled(context) &&
                    LockPrefs.protectedPackages(context).isNotEmpty()
                ) {
                    // Keep the watchdog chain alive even if this start fails
                    // (e.g. OEM background restrictions): the watchdog
                    // retries; a granted battery-optimisation exemption
                    // permits a background foreground-service start.
                    AppLockService.ensureRunning(context)
                    ServiceWatchdogReceiver.schedule(context)
                }
            }
        }
    }

    companion object {
        private const val TAG = "BlueLock"
    }
}
