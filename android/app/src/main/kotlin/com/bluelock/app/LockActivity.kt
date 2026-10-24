package com.bluelock.app

import android.content.Context
import android.content.Intent
import android.app.KeyguardManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import androidx.activity.OnBackPressedCallback
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Full-screen activity hosted over a protected app. Shows the existing
 * Flutter lock screen (app icon, name, PIN keypad, optional biometrics).
 * Finishes when the user authenticates or leaves the protected app.
 *
 * Two engine paths:
 *  - Warm: attaches the process-wide pre-warmed engine from
 *    [LockEngineCache] (see there). The engine is already booted; the
 *    protected package is pushed over the lock channel and the PIN screen
 *    replaces the idle placeholder. This removes the multi-hundred-ms to
 *    multi-second engine cold start from the authentication path.
 *  - Cold (cache empty): boots a fresh engine with initial route
 *    "lock/<package>" - the original behaviour, kept as a correct fallback.
 *
 * Extends [FlutterFragmentActivity] so androidx [BiometricPrompt] can attach
 * to this activity.
 */
class LockActivity : FlutterFragmentActivity() {

    @Volatile
    var lockedPackage: String? = null
        private set

    /**
     * Normalised Instagram username when this instance is guarding one
     * conversation instead of (or in addition to) the app-level gate.
     */
    @Volatile
    var lockedChat: String? = null
        private set

    private val mainHandler = Handler(Looper.getMainLooper())

    /** elapsedRealtime of the service's launch trigger, if provided. */
    private var launchTriggerTime = 0L

    /** Milliseconds from the service trigger to now, or -1 if unknown. */
    fun launchTimeFromTrigger(): Long =
        if (launchTriggerTime > 0) SystemClock.elapsedRealtime() - launchTriggerTime
        else -1

    /**
     * Non-null only while [LockEngineCache] holds a warmed engine: the
     * embedding then attaches that engine instead of creating a new one and
     * ignores [getInitialRoute] (the engine is already running the idle
     * "lock/" route; the package arrives via the lock channel).
     */
    override fun getCachedEngineId(): String? = LockEngineCache.engineIdOrNull()

    override fun getInitialRoute(): String {
        val pkg = intent.getStringExtra(EXTRA_PACKAGE) ?: ""
        // Never build a chat route from an unvalidated extra: if the value is
        // not a usable username, fall back to the app-level lock route so the
        // screen cannot get stuck after a successful verification.
        val chat = ChatIdentity.normalize(intent.getStringExtra(EXTRA_CHAT))
        // Deliberately WITHOUT a leading slash: a "/lock/<pkg>" initial route
        // makes Navigator.defaultGenerateInitialRoutes split the name into
        // segments and also materialise "/" and "/lock" routes underneath the
        // lock screen. The Dart router in lib/app.dart matches "lock/<pkg>".
        return if (chat.isNullOrBlank()) {
            "lock/$pkg"
        } else {
            // Usernames are already normalised to [a-z0-9._], but encode the
            // query value so the contract stays safe if that ever changes.
            "lock/$pkg?chat=${Uri.encode(chat)}"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val t0 = SystemClock.elapsedRealtime()
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        launchTriggerTime = intent.getLongExtra(EXTRA_LAUNCH_TIME, 0L)
        lockedPackage = intent.getStringExtra(EXTRA_PACKAGE)
        lockedChat = ChatIdentity.normalize(intent.getStringExtra(EXTRA_CHAT))
        isShowing = true
        showingPackage = lockedPackage
        showingChat = lockedChat
        launchPendingSince = 0L
        LockEngineCache.currentActivity = WeakReference(this)
        val cached = LockEngineCache.isReady
        Log.d(
            TAG,
            "onCreate: showing lock screen for $lockedPackage " +
                "(chat=${lockedChat != null} cachedEngine=$cached " +
                "recreated=${savedInstanceState != null})"
        )
        super.onCreate(savedInstanceState)
        // The lock is not dismissible with Back. Without this, Back popped
        // the Flutter route (finishing LockActivity) and briefly revealed the
        // protected app until the 500 ms poll relaunched the lock. The user
        // must authenticate, press Home, or leave the app.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                Log.d(TAG, "back ignored while lock screen is active")
            }
        })
        if (cached) {
            // Warm path: the Dart lock host is already running on the cached
            // engine - push the protected package so the PIN screen replaces
            // the idle placeholder. Handler registered at warm time.
            lockedPackage?.let { LockEngineCache.showLock(it, lockedChat) }
        }
        Log.i(
            TAG,
            "PERF: LockActivity.onCreate done: ${SystemClock.elapsedRealtime() - t0}ms" +
                " (total from service: ${launchTimeFromTrigger()}ms)"
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val pkg = intent.getStringExtra(EXTRA_PACKAGE)
        val chat = ChatIdentity.normalize(intent.getStringExtra(EXTRA_CHAT))
        Log.d(TAG, "onNewIntent: pkg=$pkg chat=${chat != null} current=$lockedPackage")
        if (pkg != null && (pkg != lockedPackage || chat != lockedChat)) {
            lockedPackage = pkg
            lockedChat = chat
            showingPackage = pkg
            showingChat = chat
            if (LockEngineCache.isReady) {
                // Retarget the running lock host without rebooting an engine.
                LockEngineCache.showLock(pkg, chat)
            } else {
                // Cold engine: rebuild so the fresh boot uses the new route.
                recreate()
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && launchTriggerTime > 0) {
            Log.i(
                TAG,
                "PERF: LockActivity window focused at ${launchTimeFromTrigger()}ms from service trigger"
            )
        }
    }

    override fun onDestroy() {
        // Release any in-flight biometric session owned by this activity.
        // AndroidX resets its client callback on host destroy, so without
        // this the pending channel reply (and the process-wide latch) would
        // be dropped and the Flutter side would wait forever.
        BiometricAuth.abandon(this, "LockActivity destroyed")
        isShowing = false
        showingPackage = null
        showingChat = null
        if (LockEngineCache.currentActivity?.get() === this) {
            LockEngineCache.currentActivity = null
            // Reset the cached engine's Dart host to its idle placeholder so
            // the next protected app starts from a clean lock screen.
            if (LockEngineCache.isReady) {
                LockEngineCache.clearLock()
            }
        }
        Log.d(TAG, "onDestroy: lockedPackage=$lockedPackage")
        super.onDestroy()
    }

    override fun onStop() {
        super.onStop()
        // The user left the protected app (home / recents) - dismiss the lock
        // screen; the session was never granted. Stay alive while the system
        // biometric prompt is on screen (any host path shares one session).
        if (BiometricAuth.isActive) {
            return
        }
        // Device hidden: screen off or keyguard up. The user sees and can
        // interact with nothing right now, so finishing would only make the
        // service launch this lock again on its next 500 ms tick - and it
        // would stop immediately again, looping for as long as the device
        // stays hidden. Keep the lock alive instead: it resumes the moment
        // the device becomes visible, still unauthenticated.
        if (userCannotSeeUs()) {
            Log.d(TAG, "onStop while device hidden (screen off/keyguard) - keeping lock")
            return
        }
        Log.d(TAG, "onStop without active biometric - finishing")
        finish()
    }

    /** True when the screen is off or the keyguard currently covers us. */
    private fun userCannotSeeUs(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!power.isInteractive) return true
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        @Suppress("DEPRECATION")
        return keyguard.isKeyguardLocked
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (LockEngineCache.isReady) {
            // Cached engine: NativeBridge and the lock channel were registered
            // once when the engine was warmed - do not re-register.
            Log.d(TAG, "configureFlutterEngine: cached engine - skipping registration")
            return
        }
        super.configureFlutterEngine(flutterEngine)
        NativeBridge.register(this, flutterEngine)

        val appContext = applicationContext
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.bluelock.app/lock"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "unlock" -> {
                    val ok = applyUnlock(
                        appContext,
                        call.arguments,
                        lockedPackage,
                        lockedChat
                    )
                    if (ok) {
                        result.success(null)
                        mainHandler.post { finish() }
                    } else {
                        result.error("bad_args", "target required", null)
                    }
                }
                // There is deliberately no unauthenticated "reset" method.
                // Credential replacement is performed by Dart only after a
                // verified recovery factor and is mirrored with setAuthType.
                "getBiometricStatus" -> {
                    result.success(BiometricAuth.status(appContext))
                }
                "authenticateBiometric" ->
                    authenticateBiometric(call.arguments, result)
                "markUsable" -> {
                    val total = launchTimeFromTrigger()
                    if (total >= 0) {
                        Log.i(
                            TAG,
                            "PERF: First usable lock screen UI reached in ${total}ms from launch"
                        )
                    } else {
                        Log.i(TAG, "PERF: First usable lock screen UI reached")
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun authenticateBiometric(
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        val pkg = lockedPackage
        if (pkg == null) {
            result.error("bad_args", "package required", null)
            return
        }
        val args = arguments as? Map<*, *>
        val label = args?.get("label") as? String ?: pkg
        when (
            BiometricAuth.start(
                activity = this,
                title = "Blue Lock",
                subtitle = "Authenticate to open $label"
            ) { outcome, detail ->
                Log.d(TAG, "biometric outcome=$outcome for $pkg")
                BiometricAuth.reply(result, outcome, detail)
            }
        ) {
            BiometricAuth.Start.READY -> {
                Log.d(TAG, "launching system biometric prompt for $pkg")
            }
            BiometricAuth.Start.BUSY ->
                result.error("busy", "Biometric prompt already showing", null)
            BiometricAuth.Start.HOST_NOT_READY ->
                result.error("unavailable", "Lock screen not active", null)
            BiometricAuth.Start.NO_BIOMETRICS ->
                result.error("unavailable", "No enrolled biometrics", null)
        }
    }

    companion object {
        const val EXTRA_PACKAGE = "package"
        const val EXTRA_CHAT = "chat"
        const val EXTRA_LAUNCH_TIME = "launch_time"
        private const val TAG = "BlueLock"

        @Volatile
        var isShowing: Boolean = false
            private set

        /** Package the current lock instance is guarding, if any. */
        @Volatile
        var showingPackage: String? = null
            private set

        /** Conversation username the current lock instance is guarding, if any. */
        @Volatile
        var showingChat: String? = null
            private set

        /**
         * elapsedRealtime when the service last requested a lock launch and
         * the activity had not yet come up. Cleared in onCreate; lets the
         * service suppress duplicate startActivity calls in the gap between
         * the request and the activity's first on-screen frame.
         */
        @Volatile
        var launchPendingSince: Long = 0L

        /**
         * Single completion path for both the warm cached-engine channel and
         * the cold LockActivity channel. A chat target grants only that
         * conversation's session; the app-level session is never inferred.
         *
         * Returns false when the request carries an unusable chat target, so
         * the caller can reply with an error instead of dismissing the lock.
         */
        @Suppress("UNCHECKED_CAST")
        fun applyUnlock(
            context: Context,
            arguments: Any?,
            defaultPackage: String?,
            defaultChat: String?
        ): Boolean {
            var pkg = defaultPackage
            var rawChat = defaultChat
            when (arguments) {
                is String -> pkg = arguments
                is Map<*, *> -> {
                    pkg = (arguments["package"] as? String) ?: defaultPackage
                    rawChat = (arguments["chat"] as? String) ?: defaultChat
                }
            }
            if (pkg == null) return false
            if (rawChat != null) {
                val chat = ChatIdentity.normalize(rawChat) ?: return false
                ChatLockPrefs.unlock(
                    context,
                    chat,
                    ChatLockPrefs.relockTimeout(context)
                )
                Log.d(TAG, "chat unlock accepted - dismissing lock")
            } else {
                LockPrefs.unlock(
                    context,
                    pkg,
                    LockPrefs.relockTimeout(context)
                )
                Log.d(TAG, "unlock accepted for $pkg - dismissing lock")
            }
            return true
        }
    }
}
