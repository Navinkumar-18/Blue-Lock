package com.bluelock.app

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

/**
 * Decisions around the experimental Instagram Chat Lock.
 *
 * This object never reads message content. It receives only a normalised
 * username from [ChatAccessibilityService] and decides whether the existing
 * LockActivity authentication screen must be shown again. Session expiry,
 * rate limiting and biometric/PIN/pattern/password verification are all
 * delegated to the existing Blue Lock implementation.
 */
object ChatLockCoordinator {

    private const val TAG = "BlueLock"

    /** A failed background activity launch is retried no faster than this. */
    private const val LAUNCH_RETRY_MS = 3_000L

    // ---- diagnostics exposed to the dashboard (never message content) ----
    @Volatile
    var lastDetectedUsername: String? = null
        private set

    @Volatile
    var lastDetectionStatus: String = STATUS_NOT_SCANNED
        private set

    @Volatile
    var lastDetectionAt: Long = 0L
        private set

    @Volatile
    var activeConversation: String? = null
        private set

    @Volatile
    private var lastLaunchAttemptAt: Long = 0L

    @Volatile
    private var serviceConnected: Boolean = false

    val isServiceConnected: Boolean get() = serviceConnected

    fun recordStatus(status: String) {
        lastDetectionStatus = status
        lastDetectionAt = System.currentTimeMillis()
    }

    fun onServiceConnected() {
        serviceConnected = true
        recordStatus(STATUS_SERVICE_CONNECTED)
    }

    fun onServiceDisconnected(context: Context) {
        serviceConnected = false
        activeConversation = null
        // Without the accessibility service no conversation can be detected.
        // Foreground-only sessions must not keep a chat open indefinitely.
        if (ChatLockPrefs.relockTimeout(context) <= 0) {
            ChatLockPrefs.clearForegroundOnlySessions(context)
        }
        recordStatus(STATUS_SERVICE_DISCONNECTED)
    }

    /**
     * Called whenever the accessibility scan finds a conversation header with
     * a username-shaped identifier. [username] is already normalised.
     */
    fun onConversationDetected(context: Context, username: String) {
        val id = ChatIdentity.normalize(username) ?: return
        lastDetectedUsername = id
        recordStatus(STATUS_DETECTED)

        if (!ChatLockPrefs.isMonitoringActive(context)) return

        val previous = activeConversation
        if (previous != null && previous != id) {
            // Switching directly from one conversation to another is still
            // leaving the first one: immediate relock applies to it.
            onConversationLeft(context, previous)
        }
        activeConversation = id

        if (!ChatLockPrefs.protectedChats(context).contains(id)) return
        if (ChatLockPrefs.isUnlocked(context, id)) return

        // If Instagram itself is still behind Blue Lock's app-level gate, let
        // that gate finish first. Chat protection never weakens app-lock.
        if (isInstagramAppLockPending(context)) return

        if (LockActivity.isShowing) {
            // The same chat lock is already on screen; do not stack another.
            // An app-lock prompt for Instagram is also allowed to finish first.
            return
        }

        // startActivity is asynchronous. Suppress duplicate launches while the
        // activity has not reached onCreate yet, and throttle failed launches.
        val now = SystemClock.elapsedRealtime()
        val pending = LockActivity.launchPendingSince
        if (pending != 0L && now - pending < 2_000L) return
        if (lastLaunchAttemptAt != 0L && now - lastLaunchAttemptAt < LAUNCH_RETRY_MS) {
            return
        }
        lastLaunchAttemptAt = now

        Log.d(TAG, "protected chat detected - launching authentication gate")
        launchLock(context, id)
    }

    /**
     * The current screen is a DM conversation but no username-shaped header
     * was found. Never guess: an unidentifiable conversation is reported to
     * the dashboard and left to the normal app-lock behaviour.
     */
    fun onConversationWithoutIdentifier(context: Context) {
        recordStatus(STATUS_CONVERSATION_NO_USERNAME)
    }

    /** Instagram is open on a non-conversation screen (inbox, search, ...). */
    fun onNotInConversation() {
        recordStatus(STATUS_NO_CONVERSATION)
    }

    /**
     * The user left a specific conversation. Under the default policy its
     * session ends immediately; a timed policy intentionally keeps it.
     */
    fun onConversationLeft(context: Context, username: String) {
        val id = ChatIdentity.normalize(username) ?: return
        if (ChatLockPrefs.relockTimeout(context) <= 0) {
            ChatLockPrefs.clearSession(context, id)
        }
        if (activeConversation == id) activeConversation = null
    }

    /**
     * Instagram left the foreground (or the screen turned off). Timed sessions
     * keep counting down in wall-clock time; foreground-only sessions end now.
     */
    fun onInstagramBackgrounded(context: Context) {
        if (ChatLockPrefs.relockTimeout(context) <= 0) {
            ChatLockPrefs.clearForegroundOnlySessions(context)
        }
        activeConversation = null
        recordStatus(STATUS_INSTAGRAM_BACKGROUNDED)
    }

    fun onMonitoringDisabled(context: Context) {
        activeConversation = null
        // Do not keep showing a stale conversation identifier after the user
        // turns the feature off.
        lastDetectedUsername = null
        ChatLockPrefs.clearAllSessions(context)
        recordStatus(STATUS_MONITORING_DISABLED)
    }

    /** Enabled, but the user has not protected any conversation yet. */
    fun onNoProtectedChats(context: Context) {
        activeConversation = null
        lastDetectedUsername = null
        ChatLockPrefs.clearAllSessions(context)
        recordStatus(STATUS_NO_PROTECTED_CHATS)
    }

    /** Activity recreation / screen-on: ask the service for a fresh look. */
    fun requestScan() {
        ChatAccessibilityService.requestScan()
    }

    private fun isInstagramAppLockPending(context: Context): Boolean {
        if (!LockPrefs.lockEnabled(context)) return false
        if (!LockPrefs.protectedPackages(context).contains(ChatIdentity.INSTAGRAM_PACKAGE)) {
            return false
        }
        return !LockPrefs.isUnlocked(context, ChatIdentity.INSTAGRAM_PACKAGE)
    }

    private fun launchLock(context: Context, username: String) {
        val launchTime = SystemClock.elapsedRealtime()
        LockActivity.launchPendingSince = launchTime
        val intent = Intent(context, LockActivity::class.java).apply {
            putExtra(LockActivity.EXTRA_PACKAGE, ChatIdentity.INSTAGRAM_PACKAGE)
            putExtra(LockActivity.EXTRA_CHAT, username)
            putExtra(LockActivity.EXTRA_LAUNCH_TIME, launchTime)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        try {
            context.startActivity(intent)
        } catch (t: Throwable) {
            // Background-activity-launch restrictions can refuse this on some
            // OEM builds. Surface it; the next qualifying event retries.
            Log.e(TAG, "chat lock activity launch failed", t)
        }
    }

    // ---- status vocabulary shared with Dart ----
    const val STATUS_NOT_SCANNED = "not_scanned"
    const val STATUS_SERVICE_CONNECTED = "service_connected"
    const val STATUS_SERVICE_DISCONNECTED = "service_disconnected"
    const val STATUS_DETECTED = "detected"
    const val STATUS_CONVERSATION_NO_USERNAME = "conversation_no_username"
    const val STATUS_NO_CONVERSATION = "no_conversation"
    const val STATUS_NO_WINDOW = "no_window"
    const val STATUS_INSTAGRAM_BACKGROUNDED = "instagram_backgrounded"
    const val STATUS_MONITORING_DISABLED = "monitoring_disabled"
    const val STATUS_NO_PROTECTED_CHATS = "no_protected_chats"
}
