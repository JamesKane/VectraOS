# D123. V5's exit budgets: cold start and terminal key → draw measured by Radharc and reported by rio-test in each theme, with time judged under KVM (boot-rio-kvm) and on a board for arm64 (2026-10-22, for the owner's review; extends D107, D88)

V5's exit asks for the desktop budgets green under Platinum Indigo and
under Neon Tab, on amd64 and arm64. Two had no test: cold start → first
frame (< 50 ms) and terminal key → draw (< 1 ms, on the glass in ≤ 2
frames), which step 3 rebased onto rio. The owner set the goal of
finishing V5 and left the choices here to the recommendations, so this
note is for their review.

## Decided

- **Radharc measures, since it sees both ends.** On a window it records:
  - when a key goes down to it, and the latches by then;
  - at its next present, the time since the key;
  - at the latch that shows that present, the latches since the key.
  It also records the monotonic time each window's first frame is shown.
  Its status says `key draw ... timed N` and `first frame at NS TITLE`
  (radharc(4)).
- **rio-test reports them in each shipped theme.** It loads the theme
  through Radharc's theme ctl, then:
  - types ten keys into rc's window (x, then backspace);
  - reports `terminal.key_draw.<theme>` (the median), `_max`, and
    `terminal.key_glass.<theme>` (frames);
  - starts `minimal` through the launcher's ctl and reports
    `desktop.cold_start.<theme>`, from just before the ctl write to the
    first frame shown.
  boot-rio's image carries minimal as an app for it.
- **Time is judged under KVM, not TCG.** Every QEMU test but boot-smoke-kvm
  runs under TCG, where these times measure the emulator:
  - Under TCG on amd64, key → draw read 1.8 ms. Kit's own probes put about
    1.3 ms in rio's build and 0.7 ms each in the paint list and the render;
    a malloc/free pair cost 120 ns; and a call plus one %fs load cost
    14 ns.
  - Under KVM, the same image reads 0.22 ms.
  So boot-rio-kvm (amd64, where /dev/kvm exists) boots the same image under
  KVM, as boot-smoke-kvm does. arm64 has no KVM on this machine; its time
  budgets are judged on the board (V6), as the file budgets are (D105).
  A frame count, key → glass, means the same under TCG and is judged on both.

## Measured (QEMU, a shared machine)

| Budget | amd64, KVM | arm64, TCG | Limit |
|---|---|---|---|
| terminal.key_draw (median of 10), Platinum Indigo | 0.22 ms | (2.0 ms, TCG) | < 1 ms |
| terminal.key_draw, Neon Tab | 0.21–0.32 ms | (2.0 ms, TCG) | < 1 ms |
| terminal.key_glass, both themes | 1 frame | 1 frame | ≤ 2 frames |
| desktop.cold_start, Platinum Indigo | 8–16 ms | (165 ms, TCG) | < 50 ms |
| desktop.cold_start, Neon Tab | 5.5–12 ms | (99 ms, TCG) | < 50 ms |

## The owner's decisions (2026-10-22)

- arm64's cold start and key → draw are judged on the board (V6), as
  the file budgets are (D105).
- `theme.compose.4k` stays an open target, revisited with UIGPU and
  direct scanout.
- Deskbar's idle wakeups stay untested since their flaky check went.

## Not decided here

- A bench profile for these: the owner asked for fewer profiles, so
  boot-rio-kvm reports them and the bench doesn't judge them against
  history.
- Shaping a line costs a typed key most of its time: the caret's line is
  shaped once for its carets and once to draw, under two cache keys. One
  shaping for both would halve it, if a board needs it.
