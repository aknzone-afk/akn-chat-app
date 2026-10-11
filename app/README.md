# `/app` — AKN CHAT, the Flutter app

The messenger that **replaces WhatsApp** on B.B Synthetics' business number. It runs on four staff
Android phones at once, and all four see every chat, every message and every tick live.

Flutter **3.44.0** stable · Dart **3.12** · Riverpod **3.3.2** · go_router **17.3.0** ·
FlutterFire **BoM 4.17.1** · Firebase project **`akn-chat-a7dd8`**, region **`asia-south1`**.

**Phase 3 is text messaging.** Media *arrives* and is rendered as a tasteful placeholder; the
composer *sends* text only. Photos, PDFs and voice notes are Phase 4; the bot is Phase 5.

---

## Run it

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
cd app

flutter pub get
flutter analyze                 # must be clean
flutter test                    # 13 unit tests, no emulator needed

flutter run                     # debug, on a connected phone or emulator
flutter build apk --debug       # -> build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release && flutter install    # what actually goes on the staff phones
```

`lib/firebase_options.dart` is already generated for android + ios — **do not regenerate it**.
`android/app/google-services.json` is already in place and its package name
(`com.bbsynthetics.akn_chat`) must keep matching `applicationId` in
`android/app/build.gradle.kts`. If they drift, Firebase fails at *runtime* with a config error,
not at build time.

### Profiling

Profile in `--profile` **on the oldest staff phone**, never on the simulator and never in
`--debug` — those numbers are meaningless. Turn on `debugRepaintRainbowEnabled` and confirm that a
countdown tick does **not** flash the message list; if it does, a `RepaintBoundary` has gone
missing.

---

## Log in

Firebase Auth, email + password. **Accounts are created by hand** in the Firebase console —
there is no sign-up in the app, on purpose.

Two things are required, and only having the first is the trap:

1. an **Auth user** (console → Authentication → Users), and
2. a matching **`staff/{uid}` document** in Firestore.

`firestore.rules` requires that staff row for *every single read* in the product. A user with (1)
and not (2) signs in perfectly and then sees nothing at all — so the app detects exactly that and
shows the **"Aapka account abhi set nahi hai"** screen with their email ready to copy, instead of
an empty chat list. Test this path with a throwaway user before you ship anything; it is the state
nobody remembers to try.

Create the staff row with `functions/scripts/seed.js`:

```bash
STAFF_EMAILS=you@example.com,other@example.com node functions/scripts/seed.js
```

The session is remembered — Firebase Auth persists it, and the router's guard reads it on start.

---

## What works in Phase 3

| Screen | What it does |
|---|---|
| **Login** | Email + password, Hinglish errors, "password bhool gaye?" reset, remembered session. |
| **Chat list** | Live. Initials avatar, name or number, last-message preview with a media glyph, time (`10:42` / `Kal` / weekday / date), unread badge, **24-hour window dot**, "needs attention" marker, search by name or number, pinned chats on top, long-press to pin or clear attention. |
| **Chat** | Bubbles with the time and ticks tucked into the last line, date chips, a floating sticky date chip while scrolling, quoted replies, reaction emoji folded onto their parent, media placeholders, jump-to-bottom FAB with a live count, 30-per-page lazy history, long-press menu (reply / copy / select text / resend), double-tap to reply. Header: name (tap to rename), **live window countdown**, per-chat bot toggle. Opening a chat clears the badge and calls `markChatRead`. |
| **Composer** | Optimistic send, per-chat drafts, quick replies inserted at the cursor, 4096-char cap, reply preview bar, disabled attach button (Phase 4 hook). |
| **Settings** | Read-only view of `settings/app`, light/dark/system theme, sign out. |

Ticks: `sending ⏱ · sent ✓ · delivered ✓✓ · read ✓✓ blue · failed ! red (tap to resend)`.

Light **and** dark mode throughout. Skeleton shimmer, never a blocking spinner. Offline
persistence on, 200 MB cache.

### Not in Phase 3, deliberately

Media viewers and outbound attachments (Phase 4) · the bot (Phase 5) · writing settings (there is
no `updateSettings` callable yet — see below) · push notifications · calling, status, groups,
broadcast, multi-number UI, payments.

---

## The four things that will bite whoever works on this next

**1. The security rules give the app exactly ONE write.** Creating an outgoing draft message. That
is all. Renaming a contact, pinning, the bot toggle, clearing "needs attention" and zeroing the
unread badge all go through callables, because `chats/{waId}` is `allow write: if false`.

**2. `sendMessage` takes `messageId`, not `messageDocId`.** Read
`functions/handlers/sendMessage.js` before changing the client, not the design doc.

**3. A draft's keys are an allowlist (`hasOnly`).** One stray field and the write comes back
`PERMISSION_DENIED` with *nothing in the backend logs* to explain it, because the rules engine
rejected it before any function ran. `ChatActions.draftPayload` is the single place that map is
built, and `test/widget_test.dart` asserts every key against the rules' own list — if you add a
field, that test fails until you add it to `firestore.rules` too.

**4. A failed send cannot be written down.** `messages` is `allow update, delete: if false`, so the
app can neither mark a draft `failed` nor delete it. The failure lives in
`lib/features/chat/providers/outbox.dart` — an in-memory overlay merged onto the row at render
time, plus a 90-second staleness rule for a send that died with the app. When Firestore rejects
the write outright it also rolls the local document back, so the outbox synthesises a *ghost* row;
without it the bubble would silently vanish.

### And one design decision worth knowing

**The composer is locked when the 24-hour window is shut — it does not try and fail.** The rules
would happily accept the draft; `sendMessage.js` would then write `statusRank: 99`, which is
terminal by design, and the app could never clean it up. A permanent red `!` for a message the
customer was never going to receive is worse than a locked composer, so no document is written at
all.

---

## Layout

Feature-first. `core/` is the shared plumbing; each feature owns its `domain / data / providers /
presentation`.

```
lib/
  main.dart                     Firebase init, Firestore settings, ProviderScope
  firebase_options.dart         GENERATED — leave alone
  app/                          AknChatApp, router + auth guard, theme
  core/
    errors/failure.dart         AppFailure, callGuarded, the Hinglish error table
    firebase/                   Auth/Firestore/Functions providers + path helpers
    format/formatters.dart      time, date chips, countdown, INR, phone, initials
    prefs/                      theme mode + per-chat drafts (on-device)
    widgets/                    shimmer, avatar, error/empty states
  features/
    auth/                       login, not-staff, session + guard state
    chats/                      the home list
    chat/                       the conversation, the store, the send path
    settings/                   settings/app, read-only
```

The interesting files, in the order you should read them:

1. `features/chat/data/chat_actions.dart` — the draft payload and the whole send path.
2. `features/chat/providers/chat_providers.dart` — live tail + paged history + outbox merged into
   one render-ready list, with the date/grouping flags computed once per snapshot.
3. `features/chat/presentation/widgets/message_list.dart` — why `reverse: true` is not cosmetic.
4. `features/chat/presentation/widgets/message_bubble.dart` — the reserved-`WidgetSpan` trick that
   tucks the time and ticks into the last line.

---

## Open items for the owner

1. **No `updateSettings` callable exists**, and `settings/*` is `allow write: if false`. The
   Settings screen is therefore read-only and says so on screen. One hour of backend work makes it
   editable; until then, change `settings/app` in the Firebase console.
2. **`settings/app.staffNames`** — add a `{uid: "Name"}` map by hand and outgoing bubbles will say
   who replied. No code change needed; the app already reads it. (`staff` is `allow list: if
   false`, so this map is the only way.)
3. **App Check is off** (`enforceAppCheck: false` on all three callables). The staff login is
   currently the only thing guarding the send button. Turn it on after the first working send — it
   is a coordinated backend + app change.
4. **No push notifications.** All four phones see everything live *while the app is open*; a
   backgrounded app is silent. If "replaces WhatsApp" means the phone must buzz, that is a backend
   function plus a Phase 3.5 app slice, and it is what staff will notice first.
5. **No `lastMessageStatus` on the chat document**, so the list cannot show a tick on the preview
   line. Two-line backend change if wanted.

---

## What to test first after touching the send path

1. Window **open** → send one text. Watch the icon walk `⏱ → ✓ → ✓✓ → blue ✓✓` **on all four
   phones**.
2. Window **closed** → the composer is replaced by the locked bar. No document is written.
3. **Airplane mode** → the bubble appears instantly with a clock; after ~10s a red `!` and a
   "Dobara bhejein" strip; reconnect, tap retry, and it sends **exactly once** (the backend's claim
   transaction guarantees that).
4. A user with an Auth account but **no `staff/{uid}` row** → the not-staff screen, not an empty app.
