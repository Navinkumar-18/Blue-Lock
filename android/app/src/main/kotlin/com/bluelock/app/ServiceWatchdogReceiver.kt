package com.bluelock.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

/**
 * Alarm-based liveness watchdog for [AppLockService].
 *
 * Why this exists: START_STICKY alone does not survive real-world kills.
 * When an OEM battery manager (e.g. Motorola) force-stops the app or the
 * process lands in the restricted standby bucket, Android denies the sticky
 * restart - and before this class existed, the only remaining recovery path
 * was the user manually opening Blue Lock. That is the observed
 * "protection stops working after ~24 hours" failure.
 *
 * Design constraints:
 *  - [setAndAllowWhileIdle] is used: it is inexact by design and batches
 *    with other apps' alarms, so there is no exact-alarm permission, no
 *    wake-lock grabbing and no tight restart loop.
 *  - The receiver is a no-op while protection is disabled (and stops
 *    rescheduling), so it never fights the user's explicit choice.
 *  - The alarm broadcast also grants a short background-start allowlist,
 *    so AppLockService.ensureRunning() can legally start the foreground
 *    service even while the app is otherwise in the background.
 *  - Every re-entry logs its decision: restart attempted, skipped because
 *    already running, or skipped because protection is off.
 *
 * The alarm is (re)scheduled whenever the service is created and on every
 * watchdog tick, so the chain re-arms itself as long as protection is on.
 */
class ServiceWatchdogReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        Log.i(
            TAG,
            "watchdog tick: serviceRunning=${AppLockService.isRunning} " +
                "lockEnabled=${LockPrefs.lockEnabled(context)} " +
                "protected=${LockPrefs.protectedPackages(context).size}"
        )
        val enabled = LockPrefs.lockEnabled(context) &&
            LockPrefs.protectedPackages(context).isNotEmpty()
        if (!enabled) {
            // User disabled protection or removed every protected app:
            // the watchdog must not resurrect the service.
            Log.i(TAG, "protection off - cancelling watchdog")
            cancel(context)
            return
        }
        if (!AppLockService.isRunning) {
            Log.w(TAG, "service not running - attempting recovery start")
            AppLockService.ensureRunning(context)
        }
        // Re-arm regardless: if the (re)start above failed, the next tick
        // retries; if the service is alive, this just maintains the chain.
        schedule(context)
    }

    companion object {
        private const val TAG = "BlueLock"
        private const val REQUEST_CODE = 51001

        /** ~15 min: recovers from kills within minutes, wakes ~96x/day max. */
        private const val INTERVAL_MS = 15 * 60 * 1000L

        fun schedule(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pending = pendingIntent(context)
            am.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + INTERVAL_MS,
                pending
            )
        }

        fun cancel(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pendingIntent(context))
        }

        private fun pendingIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                Intent(context, ServiceWatchdogReceiver::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
    }
}
