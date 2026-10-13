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
import androidx.core.app.NotificationCompat

/**
 * Foreground service that polls UsageStatsManager for the current foreground
 * app and launches [LockActivity] when a protected app opens without a valid
 * unlock session.
 */
class AppLockService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var lastForeground: String? = null

    private val poll = object : Runnable {
        override fun run() {
            checkForeground()
            handler.postDelayed(this, POLL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startAsForeground()
        handler.post(poll)
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
        handler.removeCallbacks(poll)
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
            stopSelf()
            return
        }
        val fg = ForegroundDetector.currentPackage(this) ?: return
        val previous = lastForeground
        lastForeground = fg

        val protectedApps = LockPrefs.protectedPackages(this)

        // Leaving a foreground-only session app invalidates its session.
        if (previous != null && previous != fg) {
            if (protectedApps.contains(previous) &&
                prefsHasForegroundOnly(previous)
            ) {
                LockPrefs.clearSession(this, previous)
            }
        }

        if (fg == packageName) return           // never lock ourselves
        if (fg in systemExcluded) return        // launcher / system UI
        if (!protectedApps.contains(fg)) return
        if (LockPrefs.isUnlocked(this, fg)) return
        if (LockActivity.isShowing) return      // avoid duplicate lock screens

        showLock(fg)
    }

    private fun prefsHasForegroundOnly(pkg: String): Boolean =
        getSharedPreferences("bluelock_prefs", Context.MODE_PRIVATE)
            .contains("fg_only_$pkg")

    private fun showLock(packageName: String) {
        val intent = Intent(this, LockActivity::class.java).apply {
            putExtra(LockActivity.EXTRA_PACKAGE, packageName)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        startActivity(intent)
    }

    companion object {
        private const val POLL_MS = 400L
        private const val NOTIFICATION_ID = 5100

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
