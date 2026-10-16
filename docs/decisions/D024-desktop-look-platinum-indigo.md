# D24. Desktop look: Platinum Indigo, not neon (2026-10-15, direction decided; details proposed)

The owner asked for a retro-future skeuomorphic look after the 1990s and
early 2000s HIGs, before flat design: BeOS, NeXT, SGI and Amiga MUI,
modernised as vector components that scale from 1080p to 4K and beyond.
It replaces the look in todhchai's `docs/desktop.md` §6 ("retro-future
cyberpunk": neon glow, chamfered cuts, CRT pass). Todhchai's structure
stays: Radharc, Tracker, Deskbar, the yellow tab with close and zoom
boxes, replicants and the trusted prompt.

- **Reference:** the [VectraOS Desktop Storyboard](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX),
  seven frames: the space workspace, its tile projection, a Tracker live
  query, the Inspector, the namespace browser and ring patch bay,
  Appearance with the trusted prompt, and the component kit. Its sources
  are copied in `docs/design/storyboard/`; the canvas is the live copy.
- **Proposed:** the tokens and material rules on the kit frame (light from
  the top left; raised presses, inset holds data, grooved groups; yellow is
  focus, blue is selection, green on black is live).
- **Proposed:** one UI scale per output, 100% to 300%; bevels and outlines
  are one logical pixel snapped to whole device pixels.
- **Proposed:** Archivo and IBM Plex Mono, openly licensed, with license
  and provenance recorded as todhchai's §6 requires for fonts.
- **Kept from §6:** SDF-drawn chrome and MSDF text, the accessibility
  theme as one switch, and the composition budget. The glow, bloom, CRT
  and glitch passes go.
