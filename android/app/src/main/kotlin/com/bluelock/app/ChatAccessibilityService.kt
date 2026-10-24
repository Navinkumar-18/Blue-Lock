package com.bluelock.app

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import androidx.core.content.ContextCompat
import java.lang.ref.WeakReference
import java.util.ArrayDeque

/**
 * Experimental Instagram DM conversation detector.
 *
 * Scope and privacy rules:
 *  - Only Instagram's active window is inspected, and only the top header
 *    region is read for a username-shaped identifier.
 *  - Message bubbles, message text, drafts, media and notifications are never
 *    read, stored, logged, screenshotted or sent anywhere.
 *  - No UI action is performed, no message is sent, no gesture is injected.
 *  - Work is event-driven and debounced; there is no polling loop.
 *
 * Detection is best-effort. Instagram does not expose a documented API for
 * individual-chat access control, and its accessibility tree can change in
 * any release. If the header does not contain a username-shaped value the
 * conversation is reported as unidentifiable and is *not* guessed.
 */
class ChatAccessibilityService : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())

    private var scanQueued = false
    private var lastScanAt = 0L
    private var pendingLeave: Runnable? = null
    private var pendingBackgroundCheck: Runnable? = null

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    // A protected conversation must not stay unlocked behind a
                    // dark screen under the default immediate-relock policy.
                    ChatLockCoordinator.onInstagramBackgrounded(this@ChatAccessibilityService)
                    scheduleScan(delayMs = 0L)
                }
                Intent.ACTION_SCREEN_ON,
                Intent.ACTION_USER_PRESENT -> scheduleScan()
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = WeakReference(this)
        connected = true
        ChatLockCoordinator.onServiceConnected()
        // A process restart must not inherit a foreground-only chat session.
        ChatLockPrefs.clearForegroundOnlySessions(this)
        try {
            ContextCompat.registerReceiver(
                this,
                screenReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_USER_PRESENT)
                },
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not register chat-lock screen receiver", e)
        }
        Log.i(TAG, "chat accessibility service connected")
        scheduleScan()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == ChatIdentity.INSTAGRAM_PACKAGE) {
            when (event.eventType) {
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> scheduleScan()
            }
        } else if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            // Another app (or the launcher/system UI) changed windows. Verify
            // with Usage Access instead of trusting transient IME/dialog events.
            scheduleBackgroundCheck(pkg)
        }
    }

    override fun onInterrupt() {
        handler.removeCallbacksAndMessages(null)
        scanQueued = false
    }

    override fun onUnbind(intent: Intent?): Boolean {
        release()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        release()
        super.onDestroy()
    }

    private fun release() {
        if (instance?.get() === this) instance = null
        connected = false
        handler.removeCallbacksAndMessages(null)
        scanQueued = false
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {
        }
        ChatLockCoordinator.onServiceDisconnected(this)
        Log.i(TAG, "chat accessibility service disconnected")
    }

    /**
     * Coalesces the event storm produced by a chat screen. A single scan is
     * enough to see the settled hierarchy; 500 ms between scans bounds the
     * cost even during rapid navigation.
     */
    private fun scheduleScan(delayMs: Long? = null) {
        if (scanQueued) return
        scanQueued = true
        val sinceLast = SystemClock.elapsedRealtime() - lastScanAt
        val delay = delayMs ?: (MIN_SCAN_INTERVAL_MS - sinceLast).coerceAtLeast(0L)
        handler.postDelayed({ scanQueued = false; scan() }, delay)
    }

    private fun scan() {
        lastScanAt = SystemClock.elapsedRealtime()

        if (!ChatLockPrefs.enabled(this)) {
            ChatLockCoordinator.onMonitoringDisabled(this)
            return
        }
        if (ChatLockPrefs.protectedChats(this).isEmpty()) {
            ChatLockCoordinator.onNoProtectedChats(this)
            return
        }
        // Never let a stale scan reinterpret the lock screen as "Instagram
        // left" while authentication is in progress, and never launch an
        // authentication activity while the device is not interactive.
        if (LockActivity.isShowing) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!power.isInteractive || keyguard.isKeyguardLocked) {
            // Never start an authentication activity behind the keyguard.
            // Foreground-only sessions end here; timed sessions keep counting.
            ChatLockCoordinator.onInstagramBackgrounded(this)
            return
        }

        val root = rootInActiveWindow ?: run {
            ChatLockCoordinator.recordStatus(ChatLockCoordinator.STATUS_NO_WINDOW)
            return
        }
        if (root.packageName?.toString() != ChatIdentity.INSTAGRAM_PACKAGE) {
            // A non-Instagram window is handled by scheduleBackgroundCheck()
            // after a Usage Access verification. Do not guess here.
            return
        }

        val detection = detectConversation(root)
        if (!detection.inConversation) {
            scheduleLeave()
            ChatLockCoordinator.onNotInConversation()
            return
        }

        cancelPendingLeave()
        val username = detection.username
        if (username == null) {
            ChatLockCoordinator.onConversationWithoutIdentifier(this)
        } else {
            ChatLockCoordinator.onConversationDetected(this, username)
        }
    }

    /**
     * The inbox, search and comment sheets must not keep a chat session alive.
     * A short debounce avoids treating a transient dialog or an emoji panel as
     * "left the conversation".
     */
    private fun scheduleLeave() {
        if (pendingLeave != null) return
        val runnable = Runnable {
            pendingLeave = null
            ChatLockCoordinator.activeConversation?.let { active ->
                ChatLockCoordinator.onConversationLeft(this, active)
            }
        }
        pendingLeave = runnable
        handler.postDelayed(runnable, LEAVE_DEBOUNCE_MS)
    }

    private fun cancelPendingLeave() {
        pendingLeave?.let { handler.removeCallbacks(it) }
        pendingLeave = null
    }

    /**
     * A window-state event from another package is not proof that Instagram
     * left (keyboards and system dialogs do this too). Confirm with the same
     * Usage Access path used by the existing app-lock service.
     */
    private fun scheduleBackgroundCheck(eventPackage: String) {
        pendingBackgroundCheck?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            pendingBackgroundCheck = null
            if (!ChatLockPrefs.isMonitoringActive(this)) return@Runnable
            if (LockActivity.isShowing) return@Runnable
            val now = System.currentTimeMillis()
            val foreground = ForegroundDetector.currentPackage(
                this,
                now - BACKGROUND_LOOKBACK_MS,
                now
            )
            val instagramActuallyVisible = foreground == ChatIdentity.INSTAGRAM_PACKAGE
            if (instagramActuallyVisible) return@Runnable
            if (foreground != null) {
                ChatLockCoordinator.onInstagramBackgrounded(this)
                return@Runnable
            }
            // Usage Access unavailable: only a launcher or another launchable
            // app is strong enough evidence to expire a foreground session.
            // Keyboards are explicitly excluded: their window-state events
            // would otherwise look like "another app" while the user types in
            // a chat, clearing the session and causing a relock loop.
            if (eventPackage != packageName &&
                !isInputMethodPackage(eventPackage) &&
                (eventPackage == homePackage() ||
                    packageManager.getLaunchIntentForPackage(eventPackage) != null)
            ) {
                ChatLockCoordinator.onInstagramBackgrounded(this)
            }
        }
        pendingBackgroundCheck = runnable
        handler.postDelayed(runnable, BACKGROUND_DEBOUNCE_MS)
    }

    private fun homePackage(): String? =
        Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_HOME)
            .resolveActivity(packageManager)
            ?.packageName

    /**
     * Keyboards are windows too. Treating one as "another app" would expire a
     * foreground-only chat session while the user is typing, then relaunch the
     * lock on the next scan - a loop. IMEs are therefore never evidence that
     * Instagram was left.
     */
    private fun isInputMethodPackage(pkg: String): Boolean =
        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.enabledInputMethodList.any { it.packageName == pkg }
        } catch (_: Exception) {
            false
        }

    // ---------------------------------------------------------------------
    // Detection: metadata only, top header only.
    // ---------------------------------------------------------------------

    private data class Detection(
        val inConversation: Boolean,
        val username: String?
    )

    private data class Candidate(
        val username: String,
        val score: Int,
        val top: Int
    )

    private fun detectConversation(root: AccessibilityNodeInfo): Detection {
        val rootBounds = Rect()
        root.getBoundsInScreen(rootBounds)
        val screenWidth = rootBounds.width().coerceAtLeast(1)
        val screenHeight = rootBounds.height().coerceAtLeast(1)

        // A DM thread always has the message composer at the bottom. Inbox
        // search fields sit at the top, so this also distinguishes the inbox.
        val composer = findComposer(root, screenHeight) ?: return Detection(false, null)

        val anchors = findHeaderAnchors(root, screenWidth, screenHeight)
        val back = anchors.firstOrNull { it.kind == AnchorKind.BACK }
        val call = anchors.firstOrNull { it.kind == AnchorKind.CALL }
        val status = anchors.firstOrNull { it.kind == AnchorKind.STATUS }
        if (back == null || (call == null && status == null)) {
            // Comments, profile and post screens can have a bottom input, but
            // they do not have the DM call/active-status header. Refuse to
            // guess rather than locking an arbitrary screen.
            return Detection(false, null)
        }

        val candidates = collectCandidates(root, screenWidth, screenHeight, back, call)
        val best = candidates.maxWithOrNull(
            compareBy<Candidate> { it.score }.thenByDescending { it.top }
        ) ?: return Detection(true, null)

        if (best.score <= 0 && best.top > (screenHeight * 0.16f)) {
            return Detection(true, null)
        }
        return Detection(true, ChatIdentity.normalize(best.username))
    }

    private fun findComposer(
        root: AccessibilityNodeInfo,
        screenHeight: Int
    ): AccessibilityNodeInfo? = findFirst(root) { node ->
        if (!node.isEditable && node.className?.toString() != "android.widget.EditText") {
            return@findFirst false
        }
        val b = Rect()
        node.getBoundsInScreen(b)
        b.width() > 0 && b.height() > 0 && b.top >= screenHeight * 0.45f
    }

    private enum class AnchorKind { BACK, CALL, STATUS }

    private data class Anchor(
        val node: AccessibilityNodeInfo,
        val kind: AnchorKind,
        val top: Int
    )

    private fun findHeaderAnchors(
        root: AccessibilityNodeInfo,
        screenWidth: Int,
        screenHeight: Int
    ): List<Anchor> {
        val anchors = ArrayList<Anchor>()
        val limit = (screenHeight * 0.30f).toInt()
        forEachNode(root, maxNodes = 500) { node ->
            val b = Rect()
            node.getBoundsInScreen(b)
            if (b.top > limit || b.width() <= 0 || b.height() <= 0) return@forEachNode
            val text = node.text?.toString()?.trim()?.lowercase().orEmpty()
            val desc = node.contentDescription?.toString()?.trim()?.lowercase().orEmpty()
            val viewId = node.viewIdResourceName?.lowercase().orEmpty()
            if (b.left < screenWidth * 0.30f &&
                (text == "back" || desc == "back" || desc == "navigate up" ||
                    desc == "go back" || text == "close" || desc == "close" ||
                    viewId.contains("back"))
            ) {
                anchors.add(Anchor(node, AnchorKind.BACK, b.top))
            }
            if (desc.contains("call") || viewId.contains("call")) {
                anchors.add(Anchor(node, AnchorKind.CALL, b.top))
            }
            if (text.startsWith("active") || text == "online" ||
                text.startsWith("last active")
            ) {
                anchors.add(Anchor(node, AnchorKind.STATUS, b.top))
            }
        }
        return anchors
    }

    private fun collectCandidates(
        root: AccessibilityNodeInfo,
        screenWidth: Int,
        screenHeight: Int,
        back: Anchor,
        call: Anchor?
    ): List<Candidate> {
        val candidates = ArrayList<Candidate>()
        val headerLimit = (screenHeight * 0.20f).toInt()
        forEachNode(root, maxNodes = 500) { node ->
            val b = Rect()
            node.getBoundsInScreen(b)
            if (b.top > headerLimit || b.width() <= 0 || b.height() <= 0) return@forEachNode
            if (node.isEditable) return@forEachNode

            val rawText = node.text?.toString()
            var username = ChatIdentity.normalize(rawText)
            if (username == null) {
                username = ChatIdentity.usernameFromProfileDescription(
                    node.contentDescription?.toString()
                )
            }
            if (username == null) return@forEachNode

            val viewId = node.viewIdResourceName?.lowercase().orEmpty()
            var score = 0
            if (viewId.contains("username")) score += 100
            if (viewId.contains("title")) score += 40
            if (viewId.contains("name")) score += 20
            if (viewId.contains("header")) score += 20

            // The candidate must live in the same compact header container as
            // the Back control (or the call control). This keeps a message
            // bubble that happens to contain a username-shaped word out.
            var inHeader = sharesCompactAncestor(
                node,
                back.node,
                screenWidth,
                screenHeight
            )
            if (!inHeader && call != null) {
                inHeader = sharesCompactAncestor(
                    node,
                    call.node,
                    screenWidth,
                    screenHeight
                )
            }
            // A value at the very top of the app window is inside the header
            // even when a vendor skin does not expose parent links.
            if (!inHeader && b.top <= (screenHeight * 0.12f).toInt()) {
                inHeader = true
            }
            if (!inHeader) return@forEachNode

            // Prefer a username-shaped text over a profile-description match.
            if (ChatIdentity.normalize(rawText) != null) score += 10
            candidates.add(Candidate(username, score, b.top))
        }
        return candidates
    }

    private fun sharesCompactAncestor(
        a: AccessibilityNodeInfo,
        b: AccessibilityNodeInfo,
        screenWidth: Int,
        screenHeight: Int
    ): Boolean {
        val lca = lowestCommonAncestor(a, b) ?: return false
        val bounds = Rect()
        lca.getBoundsInScreen(bounds)
        if (bounds.width() <= 0 || bounds.height() <= 0) return false
        return bounds.height() <= screenHeight * 0.32f &&
            bounds.width() >= screenWidth * 0.50f
    }

    private fun lowestCommonAncestor(
        a: AccessibilityNodeInfo,
        b: AccessibilityNodeInfo
    ): AccessibilityNodeInfo? {
        val ancestors = HashSet<AccessibilityNodeInfo>()
        var current: AccessibilityNodeInfo? = a
        var guard = 0
        while (current != null && guard++ < 40) {
            ancestors.add(current)
            current = current.parent
        }
        current = b
        guard = 0
        while (current != null && guard++ < 40) {
            if (ancestors.contains(current)) return current
            current = current.parent
        }
        return null
    }

    private fun findFirst(
        root: AccessibilityNodeInfo,
        maxNodes: Int = 700,
        predicate: (AccessibilityNodeInfo) -> Boolean
    ): AccessibilityNodeInfo? {
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        var visited = 0
        while (stack.isNotEmpty() && visited < maxNodes) {
            val node = stack.removeLast()
            visited++
            if (predicate(node)) return node
            for (i in node.childCount - 1 downTo 0) {
                node.getChild(i)?.let { stack.add(it) }
            }
        }
        return null
    }

    private fun forEachNode(
        root: AccessibilityNodeInfo,
        maxNodes: Int,
        visitor: (AccessibilityNodeInfo) -> Unit
    ) {
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        var visited = 0
        while (stack.isNotEmpty() && visited < maxNodes) {
            val node = stack.removeLast()
            visited++
            visitor(node)
            for (i in node.childCount - 1 downTo 0) {
                node.getChild(i)?.let { stack.add(it) }
            }
        }
    }

    companion object {
        private const val TAG = "BlueLock"

        /** Minimum spacing between hierarchy scans. */
        private const val MIN_SCAN_INTERVAL_MS = 500L

        /** A transient overlay must not be mistaken for leaving the chat. */
        private const val LEAVE_DEBOUNCE_MS = 1_200L

        /** Background verification is deliberately slower than chat scans. */
        private const val BACKGROUND_DEBOUNCE_MS = 450L
        private const val BACKGROUND_LOOKBACK_MS = 2_000L

        @Volatile
        private var instance: WeakReference<ChatAccessibilityService>? = null

        @Volatile
        var connected: Boolean = false
            private set

        fun isConnected(): Boolean = connected

        /** Used after the protected list or enable switch changes. */
        fun requestScan() {
            instance?.get()?.scheduleScan()
        }
    }
}
