package com.bluelock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The native auth type is a mirror of Flutter's AuthenticationType. These
 * tests pin the wire values (renaming one would silently desynchronise the
 * two layers) and the legacy fallback used by installs created before
 * multiple lock methods existed.
 */
class AuthTypeTest {

    @Test
    fun wireValues_matchFlutterStorageValues() {
        assertEquals("pin_4_digit", AuthType.PIN_4_DIGIT.wire)
        assertEquals("pin_6_digit", AuthType.PIN_6_DIGIT.wire)
        assertEquals("pattern", AuthType.PATTERN.wire)
        assertEquals("password", AuthType.PASSWORD.wire)
    }

    @Test
    fun fromWire_roundTripsEveryKnownValue() {
        for (type in AuthType.values()) {
            assertEquals(type, AuthType.fromWire(type.wire))
            assertTrue(AuthType.isValidWire(type.wire))
        }
    }

    @Test
    fun fromWire_missingOrUnknownFallsBackToFourDigitPin() {
        assertEquals(AuthType.PIN_4_DIGIT, AuthType.fromWire(null))
        assertEquals(AuthType.PIN_4_DIGIT, AuthType.fromWire(""))
        assertEquals(AuthType.PIN_4_DIGIT, AuthType.fromWire("face_id"))
        assertFalse(AuthType.isValidWire(null))
        assertFalse(AuthType.isValidWire("face_id"))
    }

    @Test
    fun onlyPinTypesCarryARequiredLength() {
        assertEquals(4, AuthType.PIN_4_DIGIT.pinLength!!)
        assertEquals(6, AuthType.PIN_6_DIGIT.pinLength!!)
        assertNull(AuthType.PATTERN.pinLength)
        assertNull(AuthType.PASSWORD.pinLength)

        assertTrue(AuthType.PIN_4_DIGIT.isPin)
        assertTrue(AuthType.PIN_6_DIGIT.isPin)
        assertFalse(AuthType.PATTERN.isPin)
        assertFalse(AuthType.PASSWORD.isPin)
    }

    @Test
    fun isValidPin_acceptsExactlyFourOrSixAsciiDigits() {
        assertTrue(AuthType.isValidPin("1234"))
        assertTrue(AuthType.isValidPin("654321"))

        assertFalse(AuthType.isValidPin(null))
        assertFalse(AuthType.isValidPin(""))
        assertFalse(AuthType.isValidPin("123"))
        assertFalse(AuthType.isValidPin("12345"))
        assertFalse(AuthType.isValidPin("1234567"))
        assertFalse(AuthType.isValidPin("12a4"))
        assertFalse(AuthType.isValidPin("1234 "))
        assertFalse(AuthType.isValidPin("１２３４"))
    }

    @Test
    fun defaultWire_matchesLegacyFourDigitInstall() {
        assertEquals("pin_4_digit", AuthType.DEFAULT_WIRE)
        assertEquals(AuthType.PIN_4_DIGIT, AuthType.fromWire(AuthType.DEFAULT_WIRE))
    }
}
