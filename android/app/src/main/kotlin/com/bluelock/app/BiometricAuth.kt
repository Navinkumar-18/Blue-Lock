package com.bluelock.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle

/**
 * System biometric authentication for the lock screen, backed by AndroidX
 * [BiometricPrompt]. Only reports success when the platform authentication
 * callback reports success; a failure or cancel is never treated as a pass.
 * No biometric templates or data are stored by this app.
 *
 * Every prompt in the process goes through [start], which owns one session at
 * a time ([BiometricSessionGate]) and guarantees that the pending channel
 * reply resolves exactly once:
 *  - [start] refuses busy/unready hosts *before* touching AndroidX, because
 *    AndroidX silently drops `authenticate()` calls made after
 *    `onSaveInstanceState` (no error, no callback);
 *  - a watchdog fires if no callback ever arrives, so a dropped callback can
 *    never leave the latch (and the UI's disabled button) stuck;
 *  - [abandon] releases the session from a host's `onDestroy`, which is where
 *    AndroidX resets its client callback and would otherwise swallow the
 *    final result.
 *
 * Outcomes reported to [start]'s callback:
 *  - "success"        platform-reported authentication success
 *  - "user_cancel"    user dismissed the prompt or tapped the PIN button
 *  - "error:<code>"   any other platform error, watchdog timeout or lost host
 */
object BiometricAuth {

    private const val TAG = "BlueLock"

    /** No platform callback within this window => treat the callback as lost. */
    private const val WATCHDOG_MS = 60_000L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val gate = BiometricSessionGate()

    /** Result of [start]: READY means the callback fires exactly once later. */
    enum class Start { READY, BUSY, HOST_NOT_READY, NO_BIOMETRICS }

    /** True while a system prompt session is in flight (any host activity). */
    val isActive: Boolean
        get() = gate.isActive

    private var sessionPrompt: BiometricPrompt? = null
    private var sessionWatchdog: Runnable? = null
    private var pendingOutcome: ((outcome: String, detail: String) -> Unit)? = null

    /**
     * Device status for the settings/lock UI.
     * [available]/[enrolled]: `canAuthenticate(BIOMETRIC_WEAK)` returns
     * SUCCESS only when hardware exists AND at least one biometric is
     * enrolled, so a single check answers both.
     */
    fun status(context: Context): Map<String, Any> {
        val code = canAuthenticateCode(context)
        val ok = code == BiometricManager.BIOMETRIC_SUCCESS
        val enabled = LockPrefs.biometricEnabled(context)
        Log.d(TAG, "BIOMETRIC status: canAuthenticate=$code(${codeName(code)}) enabled=$enabled")
        return mapOf(
            "available" to ok,
            "enrolled" to ok,
            "enabled" to enabled
        )
    }

    fun canAuthenticate(context: Context): Boolean =
        canAuthenticateCode(context) == BiometricManager.BIOMETRIC_SUCCESS

    private fun canAuthenticateCode(context: Context): Int =
        BiometricManager.from(context)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK)

    /**
     * Starts a prompt session for [activity]. When [Start.READY] is returned,
     * [onOutcome] is invoked exactly once (success, error, watchdog timeout or
     * host teardown). Any other result is a refusal: [onOutcome] is *not*
     * invoked and the caller answers the channel request itself.
     */
    fun start(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onOutcome: (outcome: String, detail: String) -> Unit
    ): Start {
        if (!gate.tryBegin(activity)) {
            Log.w(
                TAG,
                "BIOMETRIC start refused: busy - a prompt session is already " +
                    "active (persistent until that session ends)"
            )
            return Start.BUSY
        }
        pendingOutcome = onOutcome

        // Preflight. AndroidX logs "Unable to start authentication. Called
        // after onSaveInstanceState." and returns without ever calling back,
        // and a destroyed host resets its client callback - both used to be
        // unrecoverable because the latch only cleared in that callback.
        val hostReady = activity.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) &&
            !activity.supportFragmentManager.isStateSaved
        if (!hostReady) {
            Log.w(
                TAG,
                "BIOMETRIC start refused: host_not_ready " +
                    "(started=${activity.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)} " +
                    "stateSaved=${activity.supportFragmentManager.isStateSaved}) - " +
                    "AndroidX would drop the callback. persistent=false"
            )
            return refuse(Start.HOST_NOT_READY)
        }

        val code = canAuthenticateCode(activity)
        if (code != BiometricManager.BIOMETRIC_SUCCESS) {
            Log.w(
                TAG,
                "BIOMETRIC start refused: no_biometrics " +
                    "canAuthenticate=$code(${codeName(code)}) persistent=true"
            )
            return refuse(Start.NO_BIOMETRICS)
        }

        val watchdog = Runnable {
            complete(
                outcome = "error:timeout",
                detail = "No response from the system",
                source = "watchdog after ${WATCHDOG_MS}ms",
                lostCallback = true
            )
        }
        try {
            Log.i(TAG, "BIOMETRIC prompt starting: $subtitle")
            sessionPrompt = buildPrompt(activity, title, subtitle, ::handleCallback)
        } catch (e: RuntimeException) {
            Log.e(TAG, "BIOMETRIC start failed: ${e.message}")
            return refuse(Start.HOST_NOT_READY)
        }
        sessionWatchdog = watchdog
        mainHandler.postDelayed(watchdog, WATCHDOG_MS)
        return Start.READY
    }

    /**
     * Releases the session owned by [host] - called from the host's
     * `onDestroy`, the point where AndroidX resets its client callback and any
     * in-flight result would be dropped. The pending channel reply is still
     * delivered so the Flutter side never waits forever.
     */
    fun abandon(host: Any, reason: String) {
        if (!gate.finishIfOwnedBy(host)) return
        Log.w(
            TAG,
            "BIOMETRIC session abandoned: $reason - latch released, " +
                "later requests may start (persistent=false)"
        )
        deliverLocked(outcome = "error:host_destroyed", detail = reason)
    }

    /** Pre-session refusals: nothing was shown, so nothing must be reported. */
    private fun refuse(start: Start): Start {
        pendingOutcome = null
        gate.finish()
        return start
    }

    private fun buildPrompt(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onCallback: (outcome: String, detail: String) -> Unit
    ): BiometricPrompt {
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    result: BiometricPrompt.AuthenticationResult
                ) {
                    onCallback("success", "")
                }

                override fun onAuthenticationError(
                    errorCode: Int,
                    errString: CharSequence
                ) {
                    val cancelled =
                        errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                            errorCode == BiometricPrompt.ERROR_CANCELED
                    onCallback(
                        if (cancelled) "user_cancel" else "error:$errorCode",
                        errString.toString()
                    )
                }

                override fun onAuthenticationFailed() {
                    // Not an outcome: the system prompt stays open for retry.
                    Log.d(TAG, "BIOMETRIC attempt not recognized - prompt stays open")
                }
            }
        )
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText("Use PIN")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            .build()
        prompt.authenticate(promptInfo)
        return prompt
    }

    private fun handleCallback(outcome: String, detail: String) {
        complete(outcome, detail, source = "callback", lostCallback = false)
    }

    /**
     * Single completion point. [gate.finish] decides whether this call owns
     * the session, so the channel reply can never be sent twice and a late
     * callback cannot swallow a newer session.
     */
    private fun complete(
        outcome: String,
        detail: String,
        source: String,
        lostCallback: Boolean
    ) {
        if (!gate.finish()) {
            Log.d(TAG, "BIOMETRIC outcome ignored (session already finished): $outcome")
            return
        }
        if (lostCallback) {
            Log.w(
                TAG,
                "BIOMETRIC callback lost: $source - latch released so the " +
                    "next attempt can start (persistent=false)"
            )
        }
        deliverLocked(outcome, detail, source)
    }

    /** Assumes the caller already won the gate. */
    private fun deliverLocked(outcome: String, detail: String, source: String = "session") {
        sessionWatchdog?.let { mainHandler.removeCallbacks(it) }
        sessionWatchdog = null
        val prompt = sessionPrompt
        sessionPrompt = null
        val reply = pendingOutcome
        pendingOutcome = null
        if (prompt != null && outcome != "success" && outcome != "user_cancel") {
            // Best effort: the prompt may already be gone with its host.
            try {
                prompt.cancelAuthentication()
            } catch (_: Exception) {
            }
        }
        Log.i(TAG, "BIOMETRIC outcome=$outcome source=$source${if (detail.isNotEmpty()) " detail=$detail" else ""}")
        reply?.invoke(outcome, detail)
    }

    private fun codeName(code: Int): String = when (code) {
        BiometricManager.BIOMETRIC_SUCCESS -> "SUCCESS"
        // canAuthenticate() codes (BiometricManager).
        BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "HW_UNAVAILABLE"
        BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "NO_HARDWARE"
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "NONE_ENROLLED"
        BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED ->
            "SECURITY_UPDATE_REQUIRED"
        // Prompt error codes share the same value space (BiometricPrompt).
        BiometricPrompt.ERROR_UNABLE_TO_PROCESS -> "UNABLE_TO_PROCESS"
        BiometricPrompt.ERROR_TIMEOUT -> "TIMEOUT"
        BiometricPrompt.ERROR_NO_SPACE -> "NO_SPACE"
        BiometricPrompt.ERROR_CANCELED -> "CANCELED"
        BiometricPrompt.ERROR_VENDOR -> "VENDOR"
        BiometricPrompt.ERROR_LOCKOUT -> "LOCKOUT"
        else -> "UNKNOWN"
    }
}
