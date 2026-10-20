package com.bluelock.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat

import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.os.HandlerThread
import android.os.SystemClock

/**
 * Foreground service that polls UsageStatsManager for the current foreground
 * app and launches [LockActivity] when a protected app opens without a valid
 * unlock session.
 *
 * Reliability model (why the pieces below exist):
 *  - The poll runs on a dedicated [HandlerThread], fully native - no Flutter
 *    screen or Dart timer is ever required for protection.
 *  - START_STICKY + [ServiceWatchdogReceiver] recover from process kills.
 *    START_STICKY alone is not enough: Android denies sticky restarts after
 *    OEM force-stop / restricted-standby kills (common on Motorola devices),
 *    which is exactly the "stops working after ~24h until Blue Lock is
 *    opened" failure this service previously had. The watchdog alarm re-checks
 *    liveness every [WATCHDOG_INTERVAL_MS] and restarts the service; the
 *    alarm broadcast also grants a temporary background-start allowlist.
 *  - A main-thread watchdog restarts the poll thread if it ever stalls or
 *    dies ([STALL_TIMEOUT_MS] without a tick), so a Throwable on the poll
 *    path can no longer silently disable protection.
 *  - Usage Access is re-verified periodically (cheap AppOps check); on loss
 *    the user is notified loudly instead of protection dying invisibly.
 *  - Poll rate adapts to screen state: [POLL_MS_ON] while the screen is on
 *    (when locking matters), [POLL_MS_OFF] while it is off; a screen-on
 *    broadcast triggers an immediate poll so the first unlock is caught
 *    without waiting out the slow interval.
 */
class AppLockService : Service() {

    private val handler = Handler(Looper.getMainLooper())

    private var pollThread: HandlerThread? = null
    private var pollHandler: Handler? = null

    @Volatile
    private var lastForeground: String? = null

    /** Heartbeat of the poll loop, read by the main-thread watchdog. */
    @Volatile
    private var lastTickElapsed: Long = 0L

    /** Throttle for the svc_last_poll_time preference write. */
    @Volatile
    private var lastPollPersistedAt: Long = 0L

    @Volatile
    private var screenOn: Boolean = true

    @Volatile
    private var usageAccessLost: Boolean = false

    private var nullStreak = 0
    private var ticksSinceAccessCheck = 0L

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    Log.d(TAG, "screen off: clearing foreground-only unlock sessions")
                    LockPrefs.clearForegroundOnlySessions(this@AppLockService)
                    lastForeground = null
                    LockPrefs.setLastForeground(this@AppLockService, null)
                    screenOn = false
                }
                Intent.ACTION_SCREEN_ON -> {
                    Log.d(TAG, "screen on: immediate poll")
                    screenOn = true
                    // Catch the unlock transition immediately instead of
                    // waiting out the slow screen-off interval.
                    pollHandler?.removeCallbacks(poll)
                    pollHandler?.post(poll)
                }
            }
        }
    }

    private val poll = object : Runnable {
        override fun run() {
            try {
                checkForeground()
            } catch (t: Throwable) {
                // Throwable, not Exception: an Error here previously killed
                // the poll loop silently and protection stopped until the
                // process restarted. Log and keep the loop alive.
                Log.e(TAG, "poll failed with unexpected error", t)
            } finally {
                lastTickElapsed = SystemClock.elapsedRealtime()
                pollHandler?.postDelayed(this, if (screenOn) POLL_MS_ON else POLL_MS_OFF)
            }
        }
    }

    /**
     * Main-thread stall detector: if the poll thread stopped ticking (looper
     * wedged, thread died from a native error, etc.) it is torn down and
     * rebuilt. Cheap: one timestamp comparison every [WATCHDOG_CHECK_MS].
     */
    private val pollWatchdog = object : Runnable {
        override fun run() {
            try {
                val thread = pollThread
                val tick = lastTickElapsed
                val stalled = thread == null ||
                    !thread.isAlive ||
                    (tick != 0L &&
                        SystemClock.elapsedRealtime() - tick > STALL_TIMEOUT_MS)
                if (stalled) {
                    Log.w(TAG, "poll loop stalled (thread=${thread?.isAlive}) - restarting")
                    restartPollThread()
                }
            } catch (t: Throwable) {
                Log.e(TAG, "poll watchdog failed", t)
            }
            handler.postDelayed(this, WATCHDOG_CHECK_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "service onCreate (pid=${android.os.Process.myPid()})")
        isRunning = true
        // Call startForeground first thing: every other initialization can
        // fail without risking the "did not call startForeground()" crash.
        startAsForeground()
        restartPollThread()
        try {
            registerReceiver(
                screenReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_SCREEN_ON)
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not register screenReceiver", e)
        }
        handler.post(pollWatchdog)
        // Alarm-based watchdog: survives OEM kills that also defeat
        // START_STICKY. No-op when protection is disabled.
        ServiceWatchdogReceiver.schedule(applicationContext)
        // Pre-warm the lock screen's Flutter engine once per process, off the
        // authentication path. By the time a protected app is opened the
        // engine is booted and LockActivity can attach it instantly instead
        // of paying a full engine cold start on the critical path.
        handler.post {
            try {
                LockEngineCache.warm(applicationContext)
            } catch (e: Exception) {
                Log.w(TAG, "engine warm failed - lock will cold-boot", e)
            }
        }
    }

    /** (Re)creates the poll thread and starts the loop on it. */
    private fun restartPollThread() {
        pollHandler?.removeCallbacksAndMessages(null)
        pollThread?.quitSafely()
        val thread = HandlerThread("bluelock-poll").apply { start() }
        pollThread = thread
        val ph = Handler(thread.looper)
        pollHandler = ph
        lastTickElapsed = SystemClock.elapsedRealtime()
        // Reconcile and the poll loop run on the poll thread, in order.
        ph.post {
            try {
                reconcileStateOnStart()
            } catch (e: Exception) {
                Log.w(TAG, "reconcile failed", e)
            }
        }
        ph.post(poll)
    }

    private fun reconcileStateOnStart() {
        val savedFg = LockPrefs.getLastForeground(this)
        val lastPoll = LockPrefs.getLastPollTime(this)
        val now = System.currentTimeMillis()

        if (savedFg == null) {
            lastForeground = null
            return
        }

        // Reconcile missed transitions using Android usage events where possible.
        val transitionOccurred = ForegroundDetector.hasTransitionOccurred(this, lastPoll, now, savedFg)
        when (transitionOccurred) {
            true -> {
                // Confirmed transition away from savedFg while service was stopped.
                Log.d(TAG, "reconcile: transition occurred while stopped from $savedFg")
                if (LockPrefs.relockTimeout(this) <= 0) {
                    LockPrefs.clearSession(this, savedFg)
                }
                lastForeground = null
                LockPrefs.setLastForeground(this, null)
            }
            null -> {
                // If transition history cannot be established reliably, invalidate
                // affected immediate-relock sessions conservatively without
                // interrupting an active authentication flow.
                Log.d(TAG, "reconcile: event history inconclusive, invalidating immediate sessions conservatively")
                if (LockPrefs.relockTimeout(this) <= 0) {
                    val showing = if (LockActivity.isShowing) LockActivity.showingPackage else null
                    for (pkg in LockPrefs.protectedPackages(this)) {
                        if (pkg != showing) {
                            LockPrefs.clearSession(this, pkg)
                        }
                    }
                }
                lastForeground = null
                LockPrefs.setLastForeground(this, null)
            }
            false -> {
                // No intervening apps resumed; keep restored foreground package.
                Log.d(TAG, "reconcile: no transition observed, keeping $savedFg")
                lastForeground = savedFg
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(
            TAG,
            "service onStartCommand flags=$flags startId=$startId " +
                "stickyRestart=${intent == null}"
        )
        startAsForeground()
        if (!shouldRun()) {
            Log.i(TAG, "protection disabled or no protected apps - stopping")
            ServiceWatchdogReceiver.cancel(applicationContext)
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "service onDestroy")
        isRunning = false
        handler.removeCallbacksAndMessages(null)
        pollHandler?.removeCallbacksAndMessages(null)
        pollHandler = null
        pollThread?.quitSafely()
        pollThread = null
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun shouldRun(): Boolean =
        LockPrefs.lockEnabled(this) && LockPrefs.protectedPackages(this).isNotEmpty()

    private fun startAsForeground() {
        val channelId = "bluelock_service"
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "App protection",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Blue Lock")
            .setContentText("Protecting your apps")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (t: Throwable) {
            // Never swallow: a failed startForeground means the system kills
            // the service in ~5s, so make the failure loudly visible in logs.
            Log.e(TAG, "startForeground failed", t)
        }
    }

    private fun checkForeground() {
        if (!shouldRun()) {
            handler.post {
                ServiceWatchdogReceiver.cancel(applicationContext)
                stopSelf()
            }
            return
        }

        // Periodic Usage Access verification (cheap AppOps check, not a
        // usage-events query). Losing Usage Access silently disabled
        // protection before: currentPackage() just returns null forever.
        if (++ticksSinceAccessCheck >= ACCESS_CHECK_TICKS) {
            ticksSinceAccessCheck = 0
            val granted = NativeBridge.hasUsageAccess(this)
            if (!granted && !usageAccessLost) {
                usageAccessLost = true
                Log.w(TAG, "Usage Access lost - protection cannot detect apps. Notifying user.")
                notifyUsageAccessLost()
            } else if (granted && usageAccessLost) {
                usageAccessLost = false
                Log.i(TAG, "Usage Access restored - protection resumed")
                cancelUsageAccessNotification()
            }
        }

        val t0 = SystemClock.elapsedRealtime()
        val now = System.currentTimeMillis()
        // Persist the poll timestamp at most every [POLL_TIME_PERSIST_MS]:
        // reconcile only needs coarse granularity, and a SharedPreferences
        // write per tick ran ~216k disk-backed writes per day.
        if (now - lastPollPersistedAt >= POLL_TIME_PERSIST_MS) {
            lastPollPersistedAt = now
            LockPrefs.setLastPollTime(this, now)
        }

        // Missing result: do not update lastForeground or clear sessions.
        val fg = ForegroundDetector.currentPackage(this)
        if (fg == null) {
            nullStreak++
            return
        }
        nullStreak = 0
        val previous = lastForeground

        if (fg != previous) {
            Log.d(TAG, "foreground transition: $previous -> $fg")
            lastForeground = fg
            // Persist ONLY on meaningful transitions, avoiding polling churn.
            LockPrefs.setLastForeground(this, fg)

            val protectedApps = LockPrefs.protectedPackages(this)
            if (previous != null && protectedApps.contains(previous)) {
                // Issue 1: Prevent accidental lock loops.
                // If LockActivity is currently showing to authenticate 'previous',
                // transitioning to Blue Lock's window is part of the auth flow,
                // not an exit from the protected app.
                val isLockActivityForPrevious = (fg == packageName &&
                    LockActivity.isShowing && LockActivity.showingPackage == previous)

                if (!isLockActivityForPrevious && LockPrefs.relockTimeout(this) <= 0) {
                    Log.d(TAG, "immediate-relock: clearing session for $previous")
                    LockPrefs.clearSession(this, previous)
                }
            }
        }

        if (fg == packageName) return           // never lock ourselves
        if (fg in systemExcluded) return        // launcher / system UI
        val protectedApps = LockPrefs.protectedPackages(this)
        if (!protectedApps.contains(fg)) return
        if (LockPrefs.isUnlocked(this, fg)) {
            if (fg != previous) {
                Log.d(TAG, "$fg has an active unlock session - not locking")
            }
            return
        }

        if (LockActivity.isShowing) {
            val showing = LockActivity.showingPackage
            if (showing == fg) return           // same lock already up
            // A different protected app came to the front while a lock was
            // showing - retarget the single-instance lock activity.
            Log.d(TAG, "retargeting lock from $showing to $fg")
            showLock(fg)
            return
        }

        // startActivity is async: before the activity's onCreate runs
        // (isShowing=true) the next poll can still see the protected app in
        // the foreground and launch a duplicate. A fresh pending mark
        // suppresses that; stale marks (>2s, activity never came up) fall
        // through and relaunch.
        val pendingSince = LockActivity.launchPendingSince
        if (pendingSince != 0L &&
            SystemClock.elapsedRealtime() - pendingSince < LAUNCH_PENDING_TIMEOUT_MS
        ) {
            Log.d(TAG, "lock launch already in flight for $fg - skipping duplicate")
            return
        }

        Log.d(TAG, "$fg is protected and locked - launching LockActivity (elapsed: ${SystemClock.elapsedRealtime() - t0}ms)")
        showLock(fg)
    }

    /** Loud, user-visible signal that protection is currently ineffective. */
    private fun notifyUsageAccessLost() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    "bluelock_alerts",
                    "Protection warnings",
                    NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, "bluelock_alerts")
            .setContentTitle("Usage Access needed")
            .setContentText("App protection is paused until you re-grant Usage Access to Blue Lock.")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        try {
            manager.notify(USAGE_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "could not post usage-access notification", e)
        }
    }

    private fun cancelUsageAccessNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(USAGE_NOTIFICATION_ID)
    }

    private fun showLock(packageName: String) {
        // Issue 2 – Recents privacy note:
        // Blue Lock cannot remove the protected app's task from Android Recents
        // or set FLAG_SECURE on its window (OS-enforced: only the owning process
        // may set FLAG_SECURE on its own windows). This is an Android platform
        // limitation; it cannot be worked around without root or a system-app
        // signature. The protection requirement (re-authentication on re-open)
        // is met by session invalidation in checkForeground().
        val launchTime = SystemClock.elapsedRealtime()
        LockActivity.launchPendingSince = launchTime
        Log.d(TAG, "starting LockActivity for $packageName at $launchTime")
        val intent = Intent(this, LockActivity::class.java).apply {
            putExtra(LockActivity.EXTRA_PACKAGE, packageName)
            putExtra(LockActivity.EXTRA_LAUNCH_TIME, launchTime)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        startActivitySafe(intent)
    }

    /** [startActivity] is dispatched on the main thread (poll runs off it). */
    private fun startActivitySafe(intent: Intent) {
        handler.post {
            try {
                startActivity(intent)
            } catch (t: Throwable) {
                // Background-activity-launch restrictions can block this on
                // some OEM builds; surface it instead of looping blindly.
                Log.e(TAG, "startActivity(LockActivity) failed", t)
            }
        }
    }

    companion object {
        private const val TAG = "BlueLock"

        /** Fast interval: screen on, when locking decisions matter. */
        private const val POLL_MS_ON = 400L

        /** Slow interval: screen off - no user can open an app right now. */
        private const val POLL_MS_OFF = 2_000L

        private const val NOTIFICATION_ID = 5100
        private const val USAGE_NOTIFICATION_ID = 5101
        private const val LAUNCH_PENDING_TIMEOUT_MS = 2000L

        /** No poll tick for this long => poll thread is dead, rebuild it. */
        private const val STALL_TIMEOUT_MS = 15_000L
        private const val WATCHDOG_CHECK_MS = 30_000L

        /** Usage Access re-check cadence (~60s of screen-on ticks). */
        private const val ACCESS_CHECK_TICKS = 150L

        /** Coarse persistence granularity for the last-poll timestamp. */
        private const val POLL_TIME_PERSIST_MS = 10_000L

        /** Process-local liveness flag read by [ServiceWatchdogReceiver]. */
        @Volatile
        var isRunning: Boolean = false
            private set

        private val systemExcluded = setOf(
            "com.android.systemui",
            "com.android.launcher",
            "com.android.launcher2",
            "com.android.launcher3",
            "com.google.android.apps.nexuslauncher",
            "com.android.settings",
            "com.google.android.permissioncontroller",
            "com.android.permissioncontroller",
            "com.android.incallui"
        )

        fun ensureRunning(context: Context): Boolean {
            if (!LockPrefs.lockEnabled(context)) return false
            if (LockPrefs.protectedPackages(context).isEmpty()) return false
            val intent = Intent(context, AppLockService::class.java)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException (Android 12+
                // background start) and IllegalStateException land here.
                // Log it: this used to be swallowed, which hid the exact
                // moment protection failed to (re)start.
                Log.w(TAG, "ensureRunning failed: ${e.javaClass.simpleName}: ${e.message}")
                false
            }
        }

        fun stop(context: Context) {
            ServiceWatchdogReceiver.cancel(context)
            context.stopService(Intent(context, AppLockService::class.java))
        }
    }
}
