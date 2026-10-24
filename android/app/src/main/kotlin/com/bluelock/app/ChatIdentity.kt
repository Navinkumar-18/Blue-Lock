package com.bluelock.app

import java.util.Locale

/**
 * Pure helpers for Instagram conversation identifiers.
 *
 * Instagram publishes no public API for locking an individual DM. The only
 * local signal available to a third-party app is what Android exposes through
 * the accessibility tree. This prototype therefore accepts only text that
 * *looks like* an Instagram username (letters, digits, dots and underscores,
 * 1-30 characters). Display names are deliberately not used as identifiers:
 * they are not unique and may contain spaces, emoji or arbitrary text.
 *
 * The heuristics here are intentionally conservative. A false negative means
 * a protected conversation is shown without the extra gate; that limitation
 * is documented in CHAT_LOCK_INVESTIGATION.md. A false positive would only
 * cause an unnecessary authentication prompt, never reveal a conversation.
 *
 * No message bodies are passed through these helpers.
 */
object ChatIdentity {

    const val INSTAGRAM_PACKAGE = "com.instagram.android"

    /** Instagram usernames: 1-30 chars, letters/digits/dot/underscore. */
    private val USERNAME = Regex("^[A-Za-z0-9._]{1,30}$")

    /**
     * Labels that are structurally username-shaped but are UI chrome or
     * common message words. Matching one of these is never enough to identify
     * a conversation.
     */
    private val REJECTED = setOf(
        "instagram", "direct", "inbox", "message", "messages", "search",
        "back", "close", "send", "sent", "seen", "delivered", "now",
        "active", "online", "typing", "reply", "share", "like", "liked",
        "comment", "comments", "follow", "following", "followers",
        "profile", "photo", "photos", "video", "videos", "audio", "call",
        "calls", "voice", "record", "camera", "gallery", "sticker", "stickers",
        "gif", "gifs", "emoji", "more", "options", "details", "next", "done",
        "cancel", "delete", "edit", "add", "new", "home", "reels", "explore",
        "notes", "note", "story", "stories", "settings", "requests", "request",
        "suggested", "muted", "pinned", "restricted", "blocked", "report",
        "unread", "read", "today", "yesterday", "ago", "type", "hold",
        "http", "https", "www", "com", "instagram.com"
    )

    /**
     * Normalises a user-entered or accessibility-derived handle.
     *
     * Returns null when [raw] is not a plausible Instagram username. Callers
     * must treat null as "identifier unavailable", never as "unprotected".
     */
    fun normalize(raw: String?): String? {
        if (raw == null) return null
        var value = raw.trim()
        if (value.startsWith("@")) value = value.substring(1).trim()
        if (value.isEmpty() || value.length > 30) return null
        if (!USERNAME.matches(value)) return null
        value = value.lowercase(Locale.ROOT)
        if (value in REJECTED) return null
        // A handle made only of separators is not a real username.
        if (value.all { it == '.' || it == '_' }) return null
        return value
    }

    /** True when [text] can be used as a conversation key. */
    fun isCandidate(text: String?): Boolean = normalize(text) != null

    /**
     * Extracts a username from an accessibility content description such as
     * "Profile picture of jane_doe". Returns null for everything else, so
     * message content is never parsed as an identifier.
     */
    fun usernameFromProfileDescription(description: String?): String? {
        if (description == null) return null
        val lower = description.lowercase(Locale.ROOT)
        if (!lower.contains("profile")) return null
        val markers = listOf(
            "profile picture of ",
            "profile photo of ",
            "profile image of ",
            "profile picture: "
        )
        for (marker in markers) {
            val index = lower.indexOf(marker)
            if (index >= 0) {
                val rest = description.substring(index + marker.length)
                    .substringBefore(',')
                    .substringBefore(')')
                    .trim()
                normalize(rest)?.let { return it }
            }
        }
        if (lower.endsWith(" profile picture") || lower.endsWith(" profile photo")) {
            return normalize(description.substringBefore(" profile ").trim())
        }
        return null
    }
}
