package com.bluelock.app

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context

/** Detects the current foreground package via UsageStatsManager. */
object ForegroundDetector {

    /**
     * Newest foreground package in the [sinceMs] .. [endMs] window.
     *
     * Callers should pass the end of the previous poll as [sinceMs] so each
     * query scans only the events that arrived between two ticks instead of
     * re-reading a fixed 5-second backlog 2-3 times per second. A small
     * overlap (see [DEFAULT_OVERLAP_MS]) keeps events that land on a poll
     * boundary from being missed.
     */
    fun currentPackage(
        context: Context,
        sinceMs: Long = System.currentTimeMillis() - DEFAULT_LOOKBACK_MS,
        endMs: Long = System.currentTimeMillis()
    ): String? {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
            as? UsageStatsManager ?: return null
        if (endMs <= sinceMs) return null
        return try {
            val events = usm.queryEvents(sinceMs, endMs)
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

    /** Backlog used on the first poll after service/process start. */
    const val DEFAULT_LOOKBACK_MS = 5_000L

    /** Overlap between consecutive incremental polls (clock/boundary safety). */
    const val DEFAULT_OVERLAP_MS = 250L
}
