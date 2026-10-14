package com.bluelock.app

import android.content.Context
import android.content.SharedPreferences

/** Local persistence for lock configuration and unlock sessions. */
object LockPrefs {
    private const val FILE = "bluelock_prefs"

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
        editor.apply()
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
