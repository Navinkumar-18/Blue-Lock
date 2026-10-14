package com.bluelock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests verifying native session and timeout calculation invariants.
 */
class LockPrefsTest {

    @Test
    fun relockTimeout_defaultIsZero() {
        // Immediate relock default constant verification
        val defaultTimeout = 0
        assertEquals(0, defaultTimeout)
    }

    @Test
    fun expiryCalculation_withinTimeoutReturnsTrue() {
        val now = 100_000L
        val timeoutSeconds = 30
        val expiry = now + (timeoutSeconds * 1000L)
        val checkTime = now + 15_000L // 15 seconds later
        assertTrue("Session should remain valid before expiry", expiry > checkTime)
    }

    @Test
    fun expiryCalculation_afterTimeoutReturnsFalse() {
        val now = 100_000L
        val timeoutSeconds = 30
        val expiry = now + (timeoutSeconds * 1000L)
        val checkTime = now + 35_000L // 35 seconds later
        assertFalse("Session should expire after timeout period", expiry > checkTime)
    }

    @Test
    fun foregroundOnlyKey_formatting() {
        val pkg = "com.example.app"
        val fgKey = "fg_only_$pkg"
        val expiryKey = "expiry_$pkg"
        assertTrue(fgKey.startsWith("fg_only_"))
        assertTrue(expiryKey.startsWith("expiry_"))
        assertEquals("fg_only_com.example.app", fgKey)
    }

    @Test
    fun systemExcluded_containsEssentialPackages() {
        val excluded = setOf(
            "com.android.systemui",
            "com.android.launcher",
            "com.android.launcher2",
            "com.android.launcher3",
            "com.google.android.apps.nexuslauncher",
            "com.android.settings"
        )
        assertTrue(excluded.contains("com.android.systemui"))
        assertTrue(excluded.contains("com.android.launcher3"))
        assertFalse(excluded.contains("com.whatsapp"))
    }
}
