package com.bluelock.app

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context

/** Detects the current foreground package via UsageStatsManager. */
object ForegroundDetector {

    fun currentPackage(context: Context): String? {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
            as? UsageStatsManager ?: return null
        val now = System.currentTimeMillis()
        return try {
            val events = usm.queryEvents(now - 5_000, now)
            val event = UsageEvents.Event()
            var latestPackage: String? = null
            var latestTime = 0L
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val isForeground = if (android.os.Build.VERSION.SDK_INT >= 29) {
                    event.eventType == UsageEvents.Event.ACTIVITY_RESUMED
                } else {
                    @Suppress("DEPRECATION")
                    event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND
                }
                if (isForeground && event.timeStamp >= latestTime) {
                    latestTime = event.timeStamp
                    latestPackage = event.packageName
                }
            }
            latestPackage
        } catch (e: SecurityException) {
            null
        }
    }
}
