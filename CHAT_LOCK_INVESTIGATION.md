# Experimental Instagram Chat Lock — Investigation and Design Record

**Status: implemented as a conservative, best-effort prototype. Not verified on a
physical device or against a real Instagram build. Do not describe it as
verified exact-conversation protection.**

This document records what was investigated, what was built, what is stored,
which limitations remain, and what still has to be proven before the feature
could be considered production-ready.

---

## 1. Summary

Instagram has no public API that lets a third-party Android app lock one
direct-message conversation. The only local signal available to Blue Lock is
what Android exposes through an **optional AccessibilityService**: the visible
accessibility tree of the Instagram window.

The prototype therefore:

- identifies a conversation only by a **normalised Instagram username**
  (`^[A-Za-z0-9._]{1,30}$`, lowercased, leading `@` removed);
- explicitly rejects **display names**, group titles and username-shaped UI
  chrome;
- reports a conversation as **unidentifiable** rather than guessing when the
  header does not contain a username-shaped value;
- reuses the existing `LockActivity`, credential verification, biometric
  prompt, session primitives and rate limiting;
- stores the protected list and per-conversation sessions locally only.

The critical unresolved question is whether the Instagram version installed on
a given device exposes the username (not just the display name) in the DM
header. **That was not testable in this environment.**

---

## 2. Phase 1 investigation

### 2.1 Environment actually available

The investigation was performed on the development machine only:

```text
$ adb devices
List of devices attached
          <-- no device
```

- No physical Android device was attached at any point.
- No runnable emulator was confirmed. An AVD definition exists at
  `~/.android/avd/blperf.avd`, but no `emulator` binary was found in `PATH` or
  in the expected SDK location, so the AVD could not be booted.
- No Instagram APK exists anywhere under `/home/nerupu-navin`:
  `find /home/nerupu-navin -iname "*instagram*.apk"` returned nothing.
- Instagram could therefore not be installed, launched, dumped or inspected,
  and no accessibility hierarchy from a real Instagram DM screen exists in this
  repository or in the test results.

**Consequence:** the detector is based on documented Android accessibility
behaviour and conservative structural heuristics, not on an observed Instagram
node tree. No claim of real-world detection accuracy is made.

### 2.2 What Android makes available

With `canRetrieveWindowContent="true"`, an accessibility service can read the
active window's node tree while Instagram is in the foreground:

- node text (`AccessibilityNodeInfo.text`),
- content descriptions,
- view IDs (`viewIdResourceName`, when `flagReportViewIds` is set),
- screen bounds,
- editability and class names.

This is enough to reason about *layout* (a composer at the bottom, a back
button, a call/status control, a title in the top header). It is **not** an
Instagram API and it is not stable: any release can rename views, merge nodes,
replace the header with a web view or expose different text.

### 2.3 Identifier feasibility

| Candidate signal | Unique? | Stable? | Decision |
| :--- | :--- | :--- | :--- |
| Display name in the header | No | No | **Rejected.** Two accounts can share a name; it may contain spaces/emoji. |
| Header text that is username-shaped | Usually | Reasonably | **Accepted**, after normalisation and chrome-word rejection. |
| `@username` in header text | Usually | Reasonably | **Accepted** (the `@` is stripped). |
| Avatar content description such as `Profile picture of jane_doe` | Usually | Reasonably | **Accepted only** when it matches a known profile-label pattern. |
| Group-chat title | No | No | **Rejected.** Not a single-account identifier. |
| View ID / resource name | Not documented | No | Used only as a scoring hint, never as the identifier. |
| Notification extras | No | No | Not used; notification content is out of scope. |
| UsageStats / foreground package | No (app-level only) | Yes | Used only to know Instagram is foreground, never to identify a chat. |

The prototype therefore accepts only a value that *looks like* an Instagram
username. A false negative (no prompt) is an accepted, documented limitation.
A false positive would only cause an unnecessary authentication prompt, never
reveal a conversation.

### 2.4 Why this is not "exact chat protection"

Instagram's DM header commonly shows the participant's **display name**, and
the username may only be visible on the profile screen. If the installed build
does that, the detector will classify the conversation as
`conversation_no_username` and will **not** lock it. That is the honest,
safe outcome, but it means the feature can be ineffective on some (possibly
many) builds. This must be validated per Instagram version before any claim of
coverage.

---

## 3. Mechanism

### 3.1 Components

| Layer | File | Responsibility |
| :--- | :--- | :--- |
| Accessibility detector | `android/app/src/main/kotlin/com/bluelock/app/ChatAccessibilityService.kt` | Reads only the Instagram top header, classifies a DM thread, extracts a username. |
| Identifier rules | `.../ChatIdentity.kt` and `lib/features/chat_lock/models/chat_identity.dart` | Normalisation, rejection of display names/chrome; kept in sync. |
| Gate decisions | `.../ChatLockCoordinator.kt` | Protected-list check, session check, launch suppression, diagnostics. |
| Persistence | `.../ChatLockPrefs.kt` | Chat enable switch, protected list, relock policy, per-chat sessions. |
| Lock UI | `.../LockActivity.kt` + `lib/features/app_lock/presentation/app_lock_screen.dart` | Reuses the existing full-screen credential gate, now conversation-aware. |
| Warm engine | `.../LockEngineCache.kt` | Pushes `{package, chat}` to the cached Flutter lock host. |
| Bridge | `.../NativeBridge.kt` + `lib/core/services/native_bridge.dart` | Configuration, state and accessibility-settings intents. |
| Management UI | `lib/features/chat_lock/presentation/chat_lock_screen.dart` | Enable/disable, add/remove, detection test, relock policy, limitations, revoke. |
| Entry point | `lib/features/settings/presentation/settings_screen.dart` | Settings → Instagram Chat Lock (route is wrapped in `SelfAuthGate`). |

### 3.2 Detection algorithm

A scan runs only when all of the following are true:

1. Chat Lock is enabled **and** at least one conversation is protected.
2. The device is interactive (screen on, not keyguard-only).
3. `LockActivity` is not already showing.
4. The active window belongs to `com.instagram.android`.

The service is event-driven (`TYPE_WINDOW_STATE_CHANGED` and
`TYPE_WINDOW_CONTENT_CHANGED`). Scans are coalesced to at most one every
**500 ms**, with a **1.2 s** leave debounce so a transient dialog or emoji
panel is not mistaken for leaving the chat.

A screen is treated as a DM thread only when:

- an editable composer exists in the **bottom 55%** of the window; **and**
- the top **30%** contains a Back control; **and**
- the top **30%** also contains a call control or an active/online status label.

The username candidate must then:

- be in the top **20%** of the window;
- share a compact ancestor (height ≤ 32% of screen, width ≥ 50%) with the Back
  or call control, or sit in the very top **12%**;
- pass `ChatIdentity.normalize`.

If no candidate passes, the result is `conversation_no_username` and **no lock
is shown**. The management screen explains this instead of pretending the chat
is protected.

Traversal is capped at **500 nodes** per pass. Text is read only inside the
header regions described above; message bubbles below the header are never
inspected for text.

### 3.3 Identifier normalisation

Accepted:

- 1–30 characters from `A-Z a-z 0-9 . _`;
- optional leading `@`;
- lowercased with a locale-independent lowercasing in Kotlin.

Rejected:

- anything containing spaces, `-`, emoji or other punctuation (i.e. display
  names);
- strings made only of `.`/`_`;
- username-shaped UI chrome and common words (`messages`, `back`, `online`,
  `profile`, `instagram.com`, …), kept identical in Dart and Kotlin.

### 3.4 Sessions and relock

Per-conversation sessions live in the native `bluelock_prefs` file under a
namespace separate from app-lock:

- `chat_fg_only_<username>` — valid while the conversation stays foregrounded;
- `chat_expiry_<username>` — wall-clock expiry for timed policies.

Policies:

- **Immediate (default, 0 s)**: the session ends when the user leaves the
  conversation, leaves Instagram, turns the screen off, the service
  disconnects, the device reboots, or Blue Lock is updated.
- **30 s / 1 min / 5 min**: the expiry is stored as a timestamp and keeps
  counting while Blue Lock is backgrounded or killed.

Changing the relock policy or disabling Chat Lock clears **all** conversation
sessions. Removing a conversation clears its session. A conversation session
**never** grants the app-level Instagram session, and an app-level session
never grants a conversation session.

### 3.5 Authentication reuse

When a protected conversation is detected and has no valid session, the
coordinator starts the existing `LockActivity` with
`EXTRA_PACKAGE=com.instagram.android` and `EXTRA_CHAT=<username>`.

- Cold engine: initial route `lock/com.instagram.android?chat=<username>`.
- Warm engine: `showLock` sends `{package, chat}` to the cached lock host.
- The Dart lock screen renders the existing credential panel
  (`CredentialEntryPanel`), the existing biometric prompt and the existing
  recovery flow. Heading changes to "Conversation Locked"; the target label is
  `@username`.
- On success only, `LockSession.unlockChat` writes the conversation session.
  Failure, cancellation, lockout or a platform error writes nothing and leaves
  the lock screen in place.
- The same `PinService` verification path and persisted lockout counters are
  used, so a chat prompt cannot bypass rate limiting.
- `LockActivity` uses `FLAG_SECURE`, ignores Back, is excluded from Recents and
  stays alive over screen-off/keyguard to avoid a relaunch loop.

Duplicate launches are suppressed by `LockActivity.isShowing`, a 2 s pending
window and a 3 s retry throttle. If Instagram is still behind the app-level
gate, the chat gate waits for that gate to finish rather than stacking prompts.

### 3.6 Consent, disable and revoke

- Chat Lock is **off by default**.
- The accessibility service is **not** enabled by the app; the user must enable
  it in Android Settings. Blue Lock can only open that page.
- The management screen explains what is read, what is not read, and the
  limitations before the user adds a conversation.
- **Disable Chat Lock and revoke access** expires all chat sessions, turns the
  feature off and opens Android accessibility settings for revocation.
- Turning the feature off leaves the existing app-lock configuration, protected
  apps, credential and other settings untouched.

---

## 4. Data and privacy

Collected/stored locally:

- the enable flag;
- the relock timeout;
- the set of normalised usernames the user chose;
- per-username session flags/expiry timestamps;
- transient diagnostic status (`detected`, `conversation_no_username`, …) and
  the last detected username, held in memory for the management screen.

The list and session flags live in app-private `SharedPreferences`
(`bluelock_prefs`), which is not encrypted at rest; they contain only
usernames and timestamps, never message content. Credentials remain in the
existing encrypted secure storage and are not duplicated here.

Never collected, stored or transmitted:

- message text, drafts, media, voice notes or attachments;
- display names (they are not identifiers and are not persisted);
- notification content;
- screenshots, OCR output or screen recordings;
- keystrokes or gestures;
- any network payload. Blue Lock has no `INTERNET` permission.

The accessibility service does not perform gestures, does not filter keys, does
not tap Instagram controls and does not send messages. It declares only
`canRetrieveWindowContent` plus view-ID reporting; it deliberately omits
`canPerformGestures` and key-event filtering.

Logging is limited to lifecycle/decision messages and never includes message
content. The username may appear in the management UI and in the lock screen
label; it is not written to logcat by the chat path.

---

## 5. Security limitations and bypasses

These are inherent to a third-party, best-effort accessibility gate. They are
shown in the app and must not be hidden from users.

1. **Display-name-only headers.** If Instagram exposes only a display name, the
   conversation is unidentifiable and is not locked. This is the largest
   functional risk.
2. **Instagram UI changes.** A renamed view, a WebView header, a merged node or
   a new layout can break detection in any release. There is no contract with
   Instagram.
3. **Group chats** are unsupported and never guessed.
4. **Brief content exposure.** Android reports the window after it is drawn;
   message content can be visible for a short time before the lock activity
   covers it. This is not a secure overlay drawn before first paint.
5. **Notification previews, inbox snippets and Recents thumbnails** are not
   hidden by this feature. The lock screen itself is `FLAG_SECURE`, but
   Instagram's own surfaces are outside Blue Lock's control.
6. **Other devices and surfaces.** Instagram on another phone, a browser, a
   linked account or a cloned app is unaffected. Only this installation on this
   device is covered.
7. **Accessibility disabled or killed.** If the user revokes the permission, an
   OEM kills the service, or Android restricts the app, detection stops. Chat
   Lock does not fall back to a weaker detector.
8. **Background-activity-launch restrictions.** An `AccessibilityService`
   bound by the system is normally exempt from Android 10+ background activity
   launch limits, but some OEM builds may still refuse the launch. The
   coordinator logs the failure and retries on a later qualifying event; it
   does not loop.
9. **Root, ADB, custom ROMs, screen recording and physical access** to an
   unlocked device are outside the threat model. Blue Lock cannot prevent
   uninstall or app-data clearing either.
10. **App-level and chat-level gates are independent.** A valid Instagram
    app-lock session does not unlock a protected conversation, and a valid
    conversation session does not unlock Instagram itself.
11. **Timed grace periods** intentionally keep a conversation unlocked for the
    chosen window, including while Blue Lock is backgrounded. Immediate relock
    is the safer default.
12. **Removal is authorised by the existing Blue Lock self-auth session.** The
    management route is wrapped in `SelfAuthGate`, so it cannot be opened
    without authenticating. Within an already-unlocked Blue Lock session the
    user can remove a chat, matching how other settings work; this is not a
    second per-action credential prompt.
13. **Not OS-enforced encryption or access control.** This is an additional
    local authentication gate. It does not bypass or weaken Instagram security
    and does not encrypt Instagram's data.
14. **A username-shaped display name can cause a false positive.** If a
    participant's display name happens to contain only letters/digits/dots/
    underscores (for example `john`), it is indistinguishable from a username
    in the header and may cause an unnecessary prompt. It cannot cause a
    bypass: the prompt is extra authentication, not weaker authentication.

---

## 6. Battery and performance

- No polling loop was added. Work is triggered by accessibility events and
  coalesced to at most one scan per 500 ms.
- Background verification is debounced to 450 ms and uses the existing
  `ForegroundDetector`/UsageStats path; it does not scan Instagram content when
  another app is foreground.
- Traversal is capped at 500 nodes and text reads are restricted to the top
  header region.
- Scans stop entirely when Chat Lock is off, the protected list is empty, the
  screen is off, or the lock activity is showing.
- The existing `AppLockService` 500 ms/60 s polling behaviour is unchanged; the
  chat path only adds a foreground-transition callback.

Expected impact is small compared with the existing app-lock service, but it
has **not** been measured on a device. Battery impact remains unverified.

---

## 7. Testing performed

### 7.1 Automated checks (run in this environment)

```text
flutter analyze
  -> No issues found!

flutter test
  -> All tests passed! (122 tests)

cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug
  -> BUILD SUCCESSFUL
```

New tests:

- `test/chat_lock_test.dart`
  - username normalisation, display-name/chrome rejection, length/character
    rules;
  - `ChatLockState.fromMap` parsing and malformed-payload fallback;
  - storage defaults and roundtrip;
  - controller add/de-duplicate/remove behaviour.
- `test/lock_host_test.dart`
  - cold chat route and warm `showLock` map both carry the conversation
    username into the lock screen; `clearLock` removes it.
- `android/app/src/test/kotlin/com/bluelock/app/ChatIdentityTest.kt`
  - the same normalisation rules on the Kotlin side, including profile-label
    parsing and refusal to parse message content.

The full `./gradlew testDebugUnitTest` at the Android project root still runs
dependency tests; `shared_preferences_android` fails on this Java 17 toolchain
because SDK 36 requires Java 21 (documented in the README). The `:app:` task is
the relevant one and passes.

### 7.2 What was NOT tested

- No physical Android device.
- No emulator boot.
- No Instagram installation.
- No real Instagram accessibility hierarchy, on any version.
- No end-to-end flow: open DM → detect → lock → authenticate → return →
  relock.
- No measurement of detection latency, false negatives, false positives,
  battery, or OEM background-launch behaviour.
- No verification that the username (rather than the display name) appears in
  the DM header.

**Therefore the feature must be labelled experimental and must not be
presented as verified exact-chat protection.**

---

## 8. How to validate on a real device

Before shipping beyond an experimental flag:

1. Install a debug build on a physical device with Instagram installed and the
   account signed in.
2. Enable **Blue Lock Chat Lock** in Android accessibility settings.
3. Open a 1:1 DM, then run:
   ```bash
   adb shell uiautomator dump /sdcard/window.xml
   adb pull /sdcard/window.xml
   ```
   Inspect the top header nodes: does `text` or `content-desc` contain the
   **username**, or only the display name? Note the Instagram version.
4. Repeat for: a chat whose participant has no display name, a chat whose
   display name equals another account's, a group chat, the inbox, the profile
   screen, a reel comment sheet and a story reply.
5. Use **Detection test** in the app and confirm `detected: @username` only for
   the intended conversation.
6. Protect that chat, lock the phone, reopen the chat and confirm the
   authentication screen appears; cancel and confirm the chat stays covered;
   authenticate and confirm the chat opens; leave and re-enter and confirm
   relock policy.
7. Test with biometrics enabled/disabled, a wrong credential (lockout
   escalation), screen-off during authentication, rapid back-and-forth
   navigation, activity recreation and a process kill.
8. Measure: time from chat draw to lock, number of scans, battery over a normal
   session, and behaviour after an Instagram update.

If step 3 shows only display names on the target version, the feature does not
provide exact-chat protection on that version and should remain off or be
removed for that build.

---

## 9. Recommendation

- Keep the feature **off by default** and visibly labelled **Experimental**.
- Do not market it as "locked chat", "private chat" or "verified" until the
  real-device validation above passes on supported Instagram versions.
- Prefer documenting the false-negative behaviour over adding a display-name
  fallback: protecting the wrong conversation is worse than not prompting.
- Re-run the validation after major Instagram releases; the detector has no
  stability contract.

---

## 10. Files changed or added

Native:

- `android/app/src/main/kotlin/com/bluelock/app/ChatAccessibilityService.kt` (new)
- `.../ChatIdentity.kt` (new)
- `.../ChatLockCoordinator.kt` (new)
- `.../ChatLockPrefs.kt` (new)
- `android/app/src/main/res/xml/chat_accessibility_service.xml` (new)
- `android/app/src/main/res/values/strings.xml` (new)
- `android/app/src/main/AndroidManifest.xml` (service registration)
- `.../LockActivity.kt` (chat target, initial route, `applyUnlock`)
- `.../LockEngineCache.kt` (chat payload in `showLock`)
- `.../NativeBridge.kt` (chat state/configuration/settings)
- `.../AppLockService.kt` (chat session expiry on leaving Instagram/screen-off)
- `.../BootReceiver.kt` (clear foreground-only chat sessions)

Flutter:

- `lib/features/chat_lock/models/chat_identity.dart` (new)
- `lib/features/chat_lock/models/chat_lock_state.dart` (new)
- `lib/features/chat_lock/presentation/chat_lock_screen.dart` (new)
- `lib/core/services/native_bridge.dart`
- `lib/core/storage/app_storage.dart`
- `lib/core/state/app_controller.dart`
- `lib/features/app_lock/services/lock_session.dart`
- `lib/features/app_lock/presentation/lock_host_screen.dart`
- `lib/features/app_lock/presentation/app_lock_screen.dart`
- `lib/features/settings/presentation/settings_screen.dart`
- `lib/app.dart`

Tests/docs:

- `test/chat_lock_test.dart` (new)
- `android/app/src/test/kotlin/com/bluelock/app/ChatIdentityTest.kt` (new)
- `README.md`
- `CHAT_LOCK_INVESTIGATION.md` (this file)
