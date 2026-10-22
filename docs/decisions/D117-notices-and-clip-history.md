# D117. Notices: one shell program draws slips from what apps post and keeps the drawer, the history of notices and of the clipboard, its clips files with attributes in /data/Clips (2026-10-22, built; for the owner's review; extends D107, D111, D112, D113)

V5's step 4 part 6: notifications and the clipboard's history. Neither
donor has code for them. NeoVectra's slips drop from the bar with a
lamp that marks where each came from (03 §9.2), and are drawn by the
shell. todhchai's toasts are only a plane in its compositor's plan.
D112 put the clipboard's history in the shell, in the storyboard's
drawer (frame 07): clips as files with `Clip:Source`, `Clip:Origin` and
`Clip:Time` attributes, limited in size and age, heard from a
`clipboard` service in Radharc granted only to the shell. The owner set
the goal of finishing V5 and left the choices here to the
recommendations, so this note is for their review.

## Decided

- **One program, `notices`, does both.** It serves `/svc/notices`,
  draws the slips in a panel and keeps the drawer, a window with the
  notices' and the clipboard's histories. Both are the shell's memory
  of what happened, and one program costs one Kit app's memory rather
  than two (13 MB each as static PIEs).
  - What it replaces: nothing. No program posts notices today, and the
    clipboard keeps only its last entry.
- **An app posts a notice by writing a line to `/svc/notices/post`**,
  ndb(6) as the clipboard's lines are: `title=` (required, at most 80
  bytes), `body=` (at most 400), and `lamp=` one of `info`, `done`,
  `warn` and `fail` (`info` if none). The service is `export
  per-client`, so the notice names its app by the launcher's name for
  the client, which it can't forge. A refused line fails its write.
  Any service with `use notices` may post. Nothing is asked: a notice
  takes nothing from the user and can't be answered.
- **Slips.** A slip shows the lamp in its role's colour, the app, the
  title and the body. Slips stack under the top edge to the left of
  Deskbar, the newest on top, at most three. Each slip of `info` or
  `done` goes after 6 seconds; `warn` and `fail` stay until clicked. A
  click dismisses one. Past three, the oldest that may go goes first,
  else the newest waits. A post that would make more than 10 slips in
  10 seconds from one app is kept in the history only, not shown.
  The panel exists only while there are slips, so an empty desk has no
  window of notices' and its loop waits on nothing.
- **The history** is the last 100 notices, in memory only. A
  notice says nothing more after a restart.
- **The `clipboard` service (Radharc's).** A manifest's `grant windows
  clipboard` puts a `clipboard` file in that client's tree. Reading it
  gives each entry committed after it was opened that isn't secret, in
  `clip/new`'s form behind one header line: `entry source=APP
  origin=TITLE count=N`, then the N representations. The app is the
  writer's window's app, or its client; the origin is the title of the
  writer's focused window, or its first. Radharc keeps the last 8
  entries for a slow reader; one that falls further behind misses the
  older ones. It is a grant, not a gated service: no app asks for it,
  and only the shell's manifest names it.
- **Clips are files in `/data/Clips`.** Each entry is a file holding
  it in `clip/new`'s form, named by its number, with `Clip:Source`,
  `Clip:Origin` and `Clip:Time` (seconds since the epoch, UTC) and
  `Clip:Types` (its types, by `,`). The drawer lists them newest first,
  with the text's first line or the types. Choosing one commits it to
  the clipboard again, through `clip/new` as any client writes it. An
  entry equal to the newest clip isn't kept twice.
- **Limits:** 50 clips, 30 days and 64 MiB, the oldest removed first,
  from `Drawer:Clips`, `Drawer:Days` and `Drawer:MiB` in Settings
  (D113). Without a volume the clips are kept in memory, to the same
  limits.
- **Its tree:** `post`, `ctl` (`drawer` opens or closes the drawer,
  `dismiss N`, `paste N`, `forget N`, `clear` the clips) and `status`.
  Deskbar's VECTRAOS menu has Drawer, which writes `drawer`.

## Left out

- A drawer per document (the storyboard's: clips linked to a document
  and shown beside it). It needs a document to link to, which is the
  editor's (V11).
- Do not disturb, and notices kept across restarts.
- Actions on a slip (buttons that answer it): a notice can't be
  answered. An app that needs an answer opens a window, or routes
  (the plumber).
- Notices on the trusted path. Nothing here may imitate the prompt:
  slips are drawn in the theme's colours, which the prompt never uses.
