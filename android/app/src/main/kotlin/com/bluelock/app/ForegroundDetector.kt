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

    /**
     * Checks whether an app transition away from [expectedPackage] occurred
     * between [startTime] and [endTime]. Returns true if an activity from a
     * different package was resumed, false if only [expectedPackage] resumed,
     * or null if the event history cannot be established reliably.
     */
    fun hasTransitionOccurred(
        context: Context,
        startTime: Long,
        endTime: Long,
        expectedPackage: String
    ): Boolean? {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
            as? UsageStatsManager ?: return null
        if (startTime <= 0L || endTime <= startTime) return null
        return try {
            val events = usm.queryEvents(startTime, endTime)
            val event = UsageEvents.Event()
            var sawExpected = false
            var sawOther = false
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val isForeground = if (android.os.Build.VERSION.SDK_INT >= 29) {
                    event.eventType == UsageEvents.Event.ACTIVITY_RESUMED
                } else {
                    @Suppress("DEPRECATION")
                    event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND
                }
                if (isForeground) {
                    if (event.packageName == expectedPackage) {
                        sawExpected = true
                    } else {
                        sawOther = true
                    }
                }
            }
            if (sawOther) true else if (sawExpected) false else null
        } catch (e: SecurityException) {
            null
        }
    }
}
