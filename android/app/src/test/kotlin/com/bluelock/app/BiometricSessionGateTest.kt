package com.bluelock.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the biometric prompt latch.
 *
 * These pin down the regression behind "Biometric unlock unavailable. Enter
 * your PIN." while the screen still offered biometric unlock: the old
 * process-wide flag was cleared only from the AndroidX callback, so a
 * callback AndroidX drops silently (host destroyed / authenticate() after
 * onSaveInstanceState) left every later request refused with "busy" for the
 * rest of the process lifetime, and the pending channel reply was never sent.
 */
class BiometricSessionGateTest {

    private class Host(val name: String)

    @Test
    fun tryBegin_startsIdleSession() {
        val gate = BiometricSessionGate()
        val host = Host("lock")
        assertFalse(gate.isActive)
        assertTrue(gate.tryBegin(host))
        assertTrue(gate.isActive)
        assertTrue(gate.currentOwner === host)
    }

    @Test
    fun tryBegin_secondRequestIsBusyWhileSessionActive() {
        val gate = BiometricSessionGate()
        assertTrue(gate.tryBegin(Host("first")))
        assertFalse("a second prompt must be refused while one is active",
            gate.tryBegin(Host("second")))
        assertTrue(gate.isActive)
    }

    @Test
    fun finish_isOneShot_soTheChannelReplyCanNeverBeSentTwice() {
        val gate = BiometricSessionGate()
        assertTrue(gate.tryBegin(Host("lock")))
        assertTrue("first completion owns the reply", gate.finish())
        assertFalse("duplicate callback must be ignored", gate.finish())
        assertFalse(gate.isActive)
    }

    @Test
    fun finish_withoutActiveSessionReportsFalse() {
        assertFalse(BiometricSessionGate().finish())
    }

    @Test
    fun busyIsNotPermanent_newSessionStartsAfterCompletion() {
        val gate = BiometricSessionGate()
        assertTrue(gate.tryBegin(Host("session-1")))
        assertTrue(gate.finish())
        assertTrue("a finished session must not block the next attempt",
            gate.tryBegin(Host("session-2")))
        assertFalse("the new session is busy for others", gate.tryBegin(Host("x")))
    }

    @Test
    fun finishIfOwnedBy_releasesOnlyTheOwnHostSession() {
        val gate = BiometricSessionGate()
        val lockHost = Host("lock")
        assertTrue(gate.tryBegin(lockHost))
        assertFalse("a different host must not release this session",
            gate.finishIfOwnedBy(Host("other")))
        assertTrue("failed release must leave the session intact", gate.isActive)
        assertTrue("the owning host releases it", gate.finishIfOwnedBy(lockHost))
        assertFalse(gate.isActive)
    }

    @Test
    fun lateReleaseFromDeadHost_cannotSwallowANewerSession() {
        val gate = BiometricSessionGate()
        val deadHost = Host("destroyed")
        assertTrue(gate.tryBegin(deadHost))
        assertTrue("watchdog/callback completed the session", gate.finish())
        val liveHost = Host("live")
        assertTrue(gate.tryBegin(liveHost))
        assertFalse("onDestroy of the old host arriving late is a no-op",
            gate.finishIfOwnedBy(deadHost))
        assertTrue("the live session keeps its reply", gate.isActive)
        assertTrue(gate.finishIfOwnedBy(liveHost))
    }

    @Test
    fun abandonAfterNormalCompletion_isNoOp() {
        val gate = BiometricSessionGate()
        val host = Host("lock")
        assertTrue(gate.tryBegin(host))
        assertTrue("prompt callback answered the request", gate.finish())
        assertFalse("onDestroy after a normal unlock changes nothing",
            gate.finishIfOwnedBy(host))
        assertFalse(gate.isActive)
    }

    @Test
    fun droppedCallbackAbandonedOnDestroy_nextAttemptIsNotBusy() {
        // The reported failure: AndroidX never calls back, host is destroyed.
        val gate = BiometricSessionGate()
        val host = Host("lock")
        assertTrue(gate.tryBegin(host))
        // AndroidX drop -> only onDestroy notices. Abandon must release so
        // the following request is not refused with "busy".
        assertTrue(gate.finishIfOwnedBy(host))
        assertFalse(gate.isActive)
        assertTrue(gate.tryBegin(Host("lock-next")))
    }
}
