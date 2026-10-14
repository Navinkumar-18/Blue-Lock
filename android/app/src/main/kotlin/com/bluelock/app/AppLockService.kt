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
 * The poll itself runs on a dedicated background thread ([pollThread]): the
 * UsageStatsManager query plus SharedPreferences reads/writes used to run on
 * the Android main thread every 400ms, competing with input dispatch and
 * platform-channel work while Blue Lock was being used. All logic and timing
 * are unchanged; anything that must touch the UI (starting LockActivity,
 * stopSelf) is posted back to the main thread.
 */
class AppLockService : Service() {

    private val handler = Handler(Looper.getMainLooper())

    private var pollThread: HandlerThread? = null
    private var pollHandler: Handler? = null

    @Volatile
    private var lastForeground: String? = null

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                Log.d(TAG, "screen off: clearing foreground-only unlock sessions")
                LockPrefs.clearForegroundOnlySessions(this@AppLockService)
                lastForeground = null
                LockPrefs.setLastForeground(this@AppLockService, null)
            }
        }
    }

    private val poll = object : Runnable {
        override fun run() {
            try {
                checkForeground()
            } catch (e: Exception) {
                Log.w(TAG, "poll failed", e)
            }
            pollHandler?.postDelayed(this, POLL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val thread = HandlerThread("bluelock-poll").apply { start() }
        pollThread = thread
        pollHandler = Handler(thread.looper)
        // Reconcile and the poll loop run on the poll thread, in order.
        val ph = pollHandler!!
        ph.post {
            try {
                reconcileStateOnStart()
            } catch (e: Exception) {
                Log.w(TAG, "reconcile failed", e)
            }
        }
        try {
            registerReceiver(screenOffReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
        } catch (e: Exception) {
            Log.w(TAG, "Could not register screenOffReceiver", e)
        }
        startAsForeground()
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
        startAsForeground()
        if (!shouldRun()) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        pollHandler?.removeCallbacksAndMessages(null)
        pollHandler = null
        pollThread?.quitSafely()
        pollThread = null
        try {
            unregisterReceiver(screenOffReceiver)
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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun checkForeground() {
        if (!shouldRun()) {
            handler.post { stopSelf() }
            return
        }
        val t0 = SystemClock.elapsedRealtime()
        val now = System.currentTimeMillis()
        LockPrefs.setLastPollTime(this, now)

        // Missing result: do not update lastForeground or clear sessions.
        val fg = ForegroundDetector.currentPackage(this) ?: return
        val previous = lastForeground

        if (fg != previous) {
            Log.d(TAG, "foreground transition: $previous -> $fg")
            lastForeground = fg
            // Persist ONLY on meaningful transitions, avoiding 400ms polling churn.
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
        handler.post { startActivity(intent) }
    }

    companion object {
        private const val TAG = "BlueLock"
        private const val POLL_MS = 400L
        private const val NOTIFICATION_ID = 5100
        private const val LAUNCH_PENDING_TIMEOUT_MS = 2000L

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

        fun ensureRunning(context: Context) {
            if (!LockPrefs.lockEnabled(context)) return
            if (LockPrefs.protectedPackages(context).isEmpty()) return
            val intent = Intent(context, AppLockService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: IllegalStateException) {
                // Background-start restriction; will restart on next resume.
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AppLockService::class.java))
        }
    }
}
