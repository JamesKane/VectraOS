# D118. The lock screen: Radharc covers the screen on the trusted path, factotum asks the unlock question and checks the password against D80's one user's login key, and Control-Alt-Delete is the secure attention key (2026-10-22, built; for the owner's review; extends D80, D111, D113, D116)

V5's step 4 part 7. D111 said the lock screen is drawn on the trusted
prompt's path, in its material, under its input rule, and left the
secure attention key to be reconsidered here. D80 has one user, named by
factotum. No donor has a lock screen. The owner set the goal of
finishing V5 and left the choices here to the recommendations, so this
note is for their review.

## Decided

- **Radharc locks; factotum unlocks.** Radharc owns the screen and the
  input, and factotum owns the keys, so neither can do the other's half.
  Radharc can't `use factotum`: factotum uses Radharc for the prompt, and
  the launcher refuses a cycle. So factotum comes to Radharc, as Tracker
  does for the chooser:
  - A manifest's `grant windows lock` puts a `lock` file in that
    client's tree. Only factotum's says it.
  - factotum writes `ready user=<name>` to it when it has a login key,
    a key `proto=pass role=server service=login user=<name>
    !password=<secret>`. Radharc locks only while a ready channel is
    open, so a desk with no login key, or no factotum, can't be locked
    with no way back.
  - Reading `lock` gives `locked` or `unlocked`, each read waiting for a
    change (D114's files answered on change).
  - When it reads `locked`, factotum asks `ask=unlock user=<name>` with
    a `!password?` field on `/svc/windows/prompt`. It compares what is
    typed with the key's password itself, in constant time, and writes
    `unlock` to `lock` if they match, or asks again with `again`.
  - No password reaches Radharc's state or any file but the prompt's
    reply, which already carries typed secrets to factotum (D111).
- **Locked, Radharc shows nothing of the desk.** The screen is filled
  black, with the unlock question's panel on it, in the prompt's own
  colours. Every key, button and wheel goes to that panel or nowhere.
  Chords aren't taken. No window is given input, so no client may read
  the clipboard. Questions other than `unlock` wait until the screen is
  unlocked, and an `unlock` question is shown before any other. The
  unlock question has one button, Unlock, and Escape clears what was
  typed: there is nothing to deny. Clients keep running and drawing
  underneath.
- **What locks:**
  - `lock`, a verb of `/svc/windows/ctl` (D116), so chords and rc(1)
    reach it;
  - Deskbar's menu item Lock;
  - `super-esc`, a default chord;
  - no input for `Lock:Minutes` minutes, from Settings' `Lock` area
    (10 by default, 0 never; D113), read when Radharc starts and
    followed through its Settings watch;
  - Control-Alt-Delete.
- **Control-Alt-Delete is the secure attention key.** Radharc takes
  it before chords and windows, always. Unlocked, it locks. Locked, it
  clears the field. A window can draw a copy of the lock screen and
  read what is typed into it, but it can never see this chord. So
  pressing it before typing a password always reaches the real lock.
  It costs one chord no app may use, a cost Windows NT also paid for
  the same reason.
- **A lock survives Radharc's restart.** Radharc records `Lock:Locked`
  in Settings as it locks and unlocks, and starts locked if it is set.
- **Status:** `lock locked|unlocked ready <n> locks <n> unlocks <n>`.

## Left out

- Several users, and switching between them (D80: one user).
- A picture or the clock on the lock screen.
- Rate limits on wrong passwords. The screen is local, behind the
  prompt's half-second arming. factotum's `again` count is in its
  status.
