package com.bluelock.app

/**
 * One-shot latch for the single system biometric prompt session a process may
 * have in flight.
 *
 * Why this exists: the previous implementation kept a `biometricActive` flag
 * next to every channel handler and cleared it *only* from the AndroidX
 * [androidx.biometric.BiometricPrompt] callback. AndroidX can drop that
 * callback without any error (the host activity is destroyed, or
 * `authenticate()` is called after `onSaveInstanceState`), which left the flag
 * set for the rest of the process lifetime: every later request was rejected
 * with "busy" while the UI still offered biometric unlock.
 *
 * The latch therefore guarantees exactly-once completion:
 *  - [tryBegin] succeeds only when no session is active;
 *  - [finish] returns true for exactly one caller per session, so exactly one
 *    platform-channel reply can be sent;
 *  - [finishIfOwnedBy] releases only the session a given host owns, which is
 *    what activity teardown uses - a late release from a dead host can never
 *    swallow a newer session.
 *
 * Pure Kotlin (no Android types) so the contract is unit-testable on the JVM.
 */
class BiometricSessionGate {

    private var active = false
    private var owner: Any? = null

    /** True while a session is in flight. */
    val isActive: Boolean
        @Synchronized get() = active

    /** The host that began the active session, or null. */
    val currentOwner: Any?
        @Synchronized get() = owner

    /** Starts a session for [newOwner]. False when one is already active. */
    @Synchronized
    fun tryBegin(newOwner: Any): Boolean {
        if (active) return false
        active = true
        owner = newOwner
        return true
    }

    /** Completes the active session. True only for the first caller. */
    @Synchronized
    fun finish(): Boolean {
        if (!active) return false
        active = false
        owner = null
        return true
    }

    /** Completes the active session only when it belongs to [candidate]. */
    @Synchronized
    fun finishIfOwnedBy(candidate: Any): Boolean {
        if (!active || owner !== candidate) return false
        active = false
        owner = null
        return true
    }
}
