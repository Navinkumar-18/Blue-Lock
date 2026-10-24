package com.bluelock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the conversation-identifier rules. These values are mirrored by
 * `lib/features/chat_lock/models/chat_identity.dart`; changing one side
 * without the other would let Dart store a chat that native silently drops.
 *
 * Display names must never be accepted: a false negative (no prompt) is a
 * documented limitation, while a wrong identifier would protect the wrong
 * conversation.
 */
class ChatIdentityTest {

    @Test
    fun normalize_stripsAtAndLowercases() {
        assertEquals("jane.doe", ChatIdentity.normalize("  @Jane.Doe  "))
        assertEquals("jane_doe", ChatIdentity.normalize("jane_doe"))
        assertEquals("user123", ChatIdentity.normalize("USER123"))
        assertEquals("a", ChatIdentity.normalize("a"))
    }

    @Test
    fun normalize_rejectsDisplayNamesAndInvalidCharacters() {
        assertNull(ChatIdentity.normalize("Jane Doe"))
        assertNull(ChatIdentity.normalize("jane-doe"))
        assertNull(ChatIdentity.normalize("jane doe"))
        assertNull(ChatIdentity.normalize(""))
        assertNull(ChatIdentity.normalize("   "))
        assertNull(ChatIdentity.normalize(null))
        assertNull(ChatIdentity.normalize("a".repeat(31)))
        assertNull(ChatIdentity.normalize("..__"))
    }

    @Test
    fun normalize_rejectsUsernameShapedChrome() {
        assertNull(ChatIdentity.normalize("messages"))
        assertNull(ChatIdentity.normalize("Back"))
        assertNull(ChatIdentity.normalize("instagram.com"))
        assertNull(ChatIdentity.normalize("online"))
        assertNull(ChatIdentity.normalize("profile"))
    }

    @Test
    fun isCandidate_matchesNormalize() {
        assertTrue(ChatIdentity.isCandidate("@jane_doe"))
        assertFalse(ChatIdentity.isCandidate("Jane Doe"))
        assertFalse(ChatIdentity.isCandidate(null))
    }

    @Test
    fun usernameFromProfileDescription_acceptsOnlyProfileLabels() {
        assertEquals(
            "jane_doe",
            ChatIdentity.usernameFromProfileDescription("Profile picture of jane_doe")
        )
        assertEquals(
            "john.doe",
            ChatIdentity.usernameFromProfileDescription("Profile photo of john.doe, opens profile")
        )
        assertEquals(
            "jane_doe",
            ChatIdentity.usernameFromProfileDescription("jane_doe profile picture")
        )
    }

    @Test
    fun usernameFromProfileDescription_neverParsesMessageContent() {
        assertNull(ChatIdentity.usernameFromProfileDescription("See you at 5"))
        assertNull(ChatIdentity.usernameFromProfileDescription("Photo of a dog"))
        assertNull(ChatIdentity.usernameFromProfileDescription(null))
        // A profile label whose value is a display name is not an identifier.
        assertNull(
            ChatIdentity.usernameFromProfileDescription("Profile picture of Jane Doe")
        )
    }
}
