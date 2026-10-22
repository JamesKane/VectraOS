# D115. The Settings app is Be's preference apps, one a Settings area, with Grants among them, and the Inspector over /proc, read once a second only while someone is at the desktop (2026-10-22, built; for the owner's review; extends D107, D111, D113, D114)

V5's step 4 names "the Settings app, from Preferences and Inspector"
(D107). todhchai has both: preference apps one an area (decided there
2026-10-13, as Be had them) and an Inspector over the launcher's
`processes`, `tasks`, `handles` and `graph`, which this tree's launcher
doesn't serve. The roadmap says the Inspector reads /proc. The owner
started the part on 2026-10-22; these are the choices made in building
it.

## Built

- **One program, `preferences`, a manifest an area.** `PREFS_AREA`
  names the area; each manifest is an `app` with `preferences`, so the
  launcher lists it and Deskbar puts it in its Preferences submenu
  (D114). The areas are Settings' (`Settings.areas`: Appearance,
  Keyboard, Mouse, Deskbar) and Grants.
  - An area's app shows each of its settings with its control: − and
    + for a number in steps that suit its range, On and Off for a
    bool, a button a choice for a string. A change is written at once;
    Defaults sets the area's defaults and Revert what it had when the
    app opened. Another's change (rc's `attr`, another app) comes back
    through one watch on `/data/Settings` (D113's `Settings.touches`).
  - Grants lists D111's recorded grants (`Grants.list`), each with its
    answer and a Revoke button (`Grants.revoke`), which removes the
    attribute so the next ask prompts again. It has no Defaults or
    Revert: a recorded grant is the user's answer, not a setting.
- **The Inspector reads /proc** (proc(4)): each process's name, state,
  CPU share between two readings (its user milliseconds), and memory.
  It is the list Plan 9's `ps` gives, as a table; Enter or a click
  selects a row. It has no jobs, threads, handles, IPC graph or
  tracer: /proc serves none of them and the launcher here has no
  `processes` or `handles`. They come back when proc or the launcher
  serves them, not through a second source.
- **The Inspector reads once a second only while someone is at the
  desktop** (Radharc's `idle`, D114). A monitor that's open is meant
  to move, so it wakes; an empty desk doesn't wake it.
- **Each app's tree says what it shows** (`status`, as Deskbar's), for
  its boot test and for rc.

## Not yet

- Nothing reads Keyboard's and Mouse's settings: kbdfs doesn't repeat
  keys in software yet, and Radharc moves its pointer at one speed.
  Appearance's theme is read by no app yet either. Each reader comes with the code it
  concerns, through the same watch.
