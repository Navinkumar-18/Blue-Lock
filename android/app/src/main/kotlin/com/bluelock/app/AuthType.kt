package com.bluelock.app

/**
 * Credential types understood by both layers.
 *
 * Flutter owns credential creation/verification and stores the verifier in
 * encrypted storage. Native only mirrors the selected type so service and
 * activity recovery always agree with the Dart side. Unknown or missing
 * values fall back to a four-digit PIN, matching the Flutter migration rule
 * for installs created before multiple methods existed.
 */
enum class AuthType(val wire: String, val pinLength: Int?) {
    PIN_4_DIGIT("pin_4_digit", 4),
    PIN_6_DIGIT("pin_6_digit", 6),
    PATTERN("pattern", null),
    PASSWORD("password", null);

    val isPin: Boolean get() = pinLength != null

    companion object {
        const val DEFAULT_WIRE = "pin_4_digit"

        fun fromWire(value: String?): AuthType =
            values().firstOrNull { it.wire == value } ?: PIN_4_DIGIT

        fun isValidWire(value: String?): Boolean =
            values().any { it.wire == value }

        /** Mirrors CredentialRules validation for the PIN formats. */
        fun isValidPin(input: String?): Boolean {
            if (input == null) return false
            for (type in values()) {
                val length = type.pinLength ?: continue
                if (input.length == length && input.all { it in '0'..'9' }) {
                    return true
                }
            }
            return false
        }
    }
}
