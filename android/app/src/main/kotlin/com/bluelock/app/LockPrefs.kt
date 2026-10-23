package com.bluelock.app

import android.content.Context
import android.content.SharedPreferences
import android.os.Process

/** Local persistence for lock configuration and unlock sessions. */
object LockPrefs {
    private const val FILE = "bluelock_prefs"

    /**
     * Process that granted Blue Lock's own (self-lock) foreground-only
     * session. A process restart must never inherit an immediate-relock
     * session, so the stored pid is compared on every check.
     */
    private const val SELF_PID = "self_pid"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun protectedPackages(context: Context): Set<String> =
        prefs(context).getStringSet("protected", emptySet()) ?: emptySet()

    fun setProtectedPackages(context: Context, packages: Set<String>) {
        prefs(context).edit().putStringSet("protected", packages).apply()
    }

    fun lockEnabled(context: Context): Boolean =
        prefs(context).getBoolean("lock_enabled", true)

    fun setLockEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean("lock_enabled", enabled).apply()
    }

    /** 0 = immediately after leaving the app; otherwise seconds.
     *  Default is 0 so a fresh install / cleared prefs still locks
     *  immediately rather than silently granting a 30-second window.
     */
    fun relockTimeout(context: Context): Int =
        prefs(context).getInt("relock_timeout", 0)

    fun setRelockTimeout(context: Context, seconds: Int) {
        prefs(context).edit().putInt("relock_timeout", seconds).apply()
    }

    /** Whether biometric unlock is offered on the lock screen (user pref). */
    fun biometricEnabled(context: Context): Boolean =
        prefs(context).getBoolean("biometric_enabled", true)

    fun setBiometricEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean("biometric_enabled", enabled).apply()
    }

    /**
     * Unlock session bookkeeping. [timeoutSeconds] == 0 means the app is only
     * unlocked while it remains in the foreground.
     */
    fun unlock(context: Context, packageName: String, timeoutSeconds: Int) {
        val editor = prefs(context).edit()
        if (timeoutSeconds <= 0) {
            editor.putBoolean("fg_only_$packageName", true)
                // Do not leave an older timed session behind: after a
                // screen-off the flag is cleared, and the stale expiry would
                // otherwise keep the app unlocked until it elapses.
                .remove("expiry_$packageName")
        } else {
            val expiry = System.currentTimeMillis() + timeoutSeconds * 1000L
            editor.putLong("expiry_$packageName", expiry)
                .remove("fg_only_$packageName")
        }
        editor.apply()
    }

    fun isUnlocked(context: Context, packageName: String): Boolean {
        val p = prefs(context)
        if (p.contains("fg_only_$packageName")) return true
        val expiry = p.getLong("expiry_$packageName", -1L)
        return expiry > System.currentTimeMillis()
    }

    fun clearSession(context: Context, packageName: String) {
        prefs(context).edit()
            .remove("fg_only_$packageName")
            .remove("expiry_$packageName")
            .apply()
    }

    fun clearAllSessions(context: Context) {
        val editor = prefs(context).edit()
        for (key in prefs(context).all.keys) {
            if (key.startsWith("fg_only_") || key.startsWith("expiry_")) {
                editor.remove(key)
            }
        }
        editor.remove(SELF_PID)
        editor.apply()
    }

    /**
     * "Foreground-only" sessions are meaningless after a reboot: the protected
     * app is no longer on screen, so the next open must re-lock.
     */
    fun clearForegroundOnlySessions(context: Context) {
        val editor = prefs(context).edit()
        for (key in prefs(context).all.keys) {
            if (key.startsWith("fg_only_")) {
                editor.remove(key)
            }
        }
        editor.remove(SELF_PID)
        editor.apply()
    }

    // ---- Self-lock: Blue Lock's own unlock session ----
    //
    // Keyed by Blue Lock's own package name so it can never collide with a
    // third-party protected-app session. Blue Lock itself is never added to
    // the protected-package list (that would make AppLockService relaunch
    // LockActivity over our own UI); self-authentication is a separate
    // app-entry gate that reuses these same session primitives.

    /**
     * Grants Blue Lock a self session under the current relock policy.
     * Immediate (0s) sessions are foreground-only and additionally bound to
     * the granting process so a process restart cannot inherit them.
     */
    fun unlockSelf(context: Context) {
        val pkg = context.packageName
        unlock(context, pkg, relockTimeout(context))
        prefs(context).edit().putLong(SELF_PID, Process.myPid().toLong()).apply()
    }

    fun isSelfUnlocked(context: Context): Boolean {
        val pkg = context.packageName
        if (prefs(context).contains("fg_only_$pkg")) {
            // Immediate relock: valid only while the granting process lives.
            return prefs(context).getLong(SELF_PID, -1L) == Process.myPid().toLong()
        }
        // Timed session: wall-clock expiry, same primitive as protected apps.
        return isUnlocked(context, pkg)
    }

    /**
     * Called when Blue Lock leaves the foreground. Immediate policy expires
     * the session at once; timed policies retain it for exactly the
     * configured duration starting from this moment. An already-invalid
     * session is cleared, never re-validated - otherwise backgrounding from
     * the lock screen would silently unlock the app.
     */
    fun onSelfBackgrounded(context: Context) {
        val timeout = relockTimeout(context)
        if (timeout > 0 && isSelfUnlocked(context)) {
            unlock(context, context.packageName, timeout)
        } else {
            clearSelfSession(context)
        }
    }

    fun clearSelfSession(context: Context) {
        clearSession(context, context.packageName)
        prefs(context).edit().remove(SELF_PID).apply()
    }

    fun resetAll(context: Context) {
        prefs(context).edit().clear().apply()
    }

    fun getLastForeground(context: Context): String? =
        prefs(context).getString("svc_last_fg", null)

    fun setLastForeground(context: Context, pkg: String?) {
        val editor = prefs(context).edit()
        if (pkg == null) {
            editor.remove("svc_last_fg")
        } else {
            editor.putString("svc_last_fg", pkg)
        }
        editor.apply()
    }

    fun getLastPollTime(context: Context): Long =
        prefs(context).getLong("svc_last_poll_time", 0L)

    fun setLastPollTime(context: Context, timeMs: Long) {
        prefs(context).edit().putLong("svc_last_poll_time", timeMs).apply()
    }
}
