package com.bluelock.app

import android.content.Context
import android.content.SharedPreferences

/**
 * Local persistence for the experimental Instagram Chat Lock.
 *
 * Only normalised Instagram usernames are stored. Message text, display
 * names, media and notification content are never collected. The service
 * reads these preferences directly, so chat protection continues while the
 * Flutter dashboard is backgrounded.
 */
object ChatLockPrefs {
    private const val FILE = "bluelock_prefs"

    private const val KEY_ENABLED = "chat_lock_enabled"
    private const val KEY_PROTECTED = "chat_protected"
    private const val KEY_RELOCK = "chat_relock_timeout"

    // Same session primitives as app-lock, but in a separate key namespace so
    // a conversation can never inherit an app-level unlock session.
    private const val PREFIX_FG = "chat_fg_only_"
    private const val PREFIX_EXPIRY = "chat_expiry_"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    // ---- configuration ----

    fun enabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    /** Returns true when the stored value changed. */
    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        val changed = enabled(context) != enabled
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
        if (!enabled) clearAllSessions(context)
        return changed
    }

    fun protectedChats(context: Context): Set<String> {
        val raw = prefs(context).getStringSet(KEY_PROTECTED, emptySet()) ?: emptySet()
        return raw.mapNotNull { ChatIdentity.normalize(it) }.toSet()
    }

    /**
     * Stores only valid, normalised usernames. Returns the previous set so the
     * caller can clear sessions for removed conversations without another
     * preference read race.
     */
    fun setProtectedChats(context: Context, chats: Collection<String>): Set<String> {
        val previous = protectedChats(context)
        val normalized = chats.mapNotNull { ChatIdentity.normalize(it) }.toSet()
        prefs(context).edit().putStringSet(KEY_PROTECTED, normalized).apply()
        return previous
    }

    /** 0 = relock as soon as the conversation is left; otherwise seconds. */
    fun relockTimeout(context: Context): Int =
        prefs(context).getInt(KEY_RELOCK, 0)

    /** Returns true when the stored value changed. */
    fun setRelockTimeout(context: Context, seconds: Int): Boolean {
        val safe = seconds.coerceAtLeast(0)
        val changed = relockTimeout(context) != safe
        prefs(context).edit().putInt(KEY_RELOCK, safe).apply()
        // A session granted under the old policy must not survive the change.
        if (changed) clearAllSessions(context)
        return changed
    }

    /** The accessibility service only does work when this is true. */
    fun isMonitoringActive(context: Context): Boolean =
        enabled(context) && protectedChats(context).isNotEmpty()

    // ---- per-conversation sessions ----

    fun unlock(context: Context, username: String, timeoutSeconds: Int) {
        val id = ChatIdentity.normalize(username) ?: return
        val editor = prefs(context).edit()
        if (timeoutSeconds <= 0) {
            editor.putBoolean(PREFIX_FG + id, true)
                .remove(PREFIX_EXPIRY + id)
        } else {
            val expiry = System.currentTimeMillis() + timeoutSeconds * 1000L
            editor.putLong(PREFIX_EXPIRY + id, expiry)
                .remove(PREFIX_FG + id)
        }
        editor.apply()
    }

    fun isUnlocked(context: Context, username: String): Boolean {
        val id = ChatIdentity.normalize(username) ?: return false
        val p = prefs(context)
        if (p.contains(PREFIX_FG + id)) return true
        val expiry = p.getLong(PREFIX_EXPIRY + id, -1L)
        return expiry > System.currentTimeMillis()
    }

    fun clearSession(context: Context, username: String) {
        val id = ChatIdentity.normalize(username) ?: return
        prefs(context).edit()
            .remove(PREFIX_FG + id)
            .remove(PREFIX_EXPIRY + id)
            .apply()
    }

    fun clearAllSessions(context: Context) {
        val editor = prefs(context).edit()
        for (key in prefs(context).all.keys) {
            if (key.startsWith(PREFIX_FG) || key.startsWith(PREFIX_EXPIRY)) {
                editor.remove(key)
            }
        }
        editor.apply()
    }

    /** Screen-off, reboot and leaving Instagram expire foreground-only chat sessions. */
    fun clearForegroundOnlySessions(context: Context) {
        val editor = prefs(context).edit()
        for (key in prefs(context).all.keys) {
            if (key.startsWith(PREFIX_FG)) editor.remove(key)
        }
        editor.apply()
    }
}
