package com.bluelock.app

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * System biometric authentication for the lock screen, backed by AndroidX
 * [BiometricPrompt]. Only reports success when the platform authentication
 * callback reports success; a failure or cancel is never treated as a pass.
 * No biometric templates or data are stored by this app.
 */
object BiometricAuth {

    /**
     * Device status for the settings/lock UI.
     * [available]/[enrolled]: `canAuthenticate(BIOMETRIC_WEAK)` returns
     * SUCCESS only when hardware exists AND at least one biometric is
     * enrolled, so a single check answers both.
     */
    fun status(context: Context): Map<String, Any> {
        val canAuthenticate = canAuthenticate(context)
        return mapOf(
            "available" to canAuthenticate,
            "enrolled" to canAuthenticate,
            "enabled" to LockPrefs.biometricEnabled(context)
        )
    }

    fun canAuthenticate(context: Context): Boolean =
        BiometricManager.from(context)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) ==
            BiometricManager.BIOMETRIC_SUCCESS

    /**
     * Shows the system biometric prompt. [onOutcome] receives:
     *  - "success"        - platform-reported authentication success
     *  - "user_cancel"    - user dismissed the prompt or tapped the PIN button
     *  - "error:<code>"   - any other platform error (lockout, hardware
     *                       failure, ...)
     *
     * [onAuthenticationFailed] (e.g. unrecognized finger) keeps the system
     * prompt open for retry and is intentionally not reported as an outcome.
     */
    fun showPrompt(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onOutcome: (outcome: String, detail: String) -> Unit
    ): BiometricPrompt {
        val executor = ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(
            activity,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    result: BiometricPrompt.AuthenticationResult
                ) {
                    onOutcome("success", "")
                }

                override fun onAuthenticationError(
                    errorCode: Int,
                    errString: CharSequence
                ) {
                    val cancelled =
                        errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                            errorCode == BiometricPrompt.ERROR_CANCELED
                    onOutcome(
                        if (cancelled) "user_cancel" else "error:$errorCode",
                        errString.toString()
                    )
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
}
