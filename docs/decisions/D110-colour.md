# D110. Colour: pixels are 8-bit sRGB unless tagged, and every blend is done in linear light, text's too, with a contrast knob (2026-10-18, decided; details proposed; extends D91, D107, D109)

D107 puts three designs before Radharc's step, and colour is the
first: "sRGB unless tagged, blended in linear light". Today nothing
blends in linear light. todhchai's UICore (`Render.swift`'s `mix`),
its text canvas (`TextLayout.swift`'s `Canvas.blend`) and NeoVectra's
`vx_font_blend` all interpolate the sRGB bytes directly, and
todhchai's Radharc only copies opaque pixels. Only NeoVectra tags a
buffer (`vx_buffer_desc`'s transfer, primaries and alpha), and it acts
on none of the tags. todhchai's desktop.md wanted FP16 scRGB
composition and theme colours in nits, and `docs/theming.md` §2.1
repeated that; D109 then wrote theme colours as sRGB hex and left
linear light and nits to this entry.

## Decided

The owner chose these (2026-10-18):

- **Pixels are 8-bit and sRGB-encoded,** in surfaces, in the scene and
  in the framebuffer, as the GOP framebuffer is. Radharc does not
  compose in FP16. Each blend decodes to linear light through a table,
  blends there, and encodes the result back. That stays cheap on the
  CPU composer, and HDR waits for the GPU (V5's step 6).
- **Text is blended in linear light too, with a contrast knob.**
  Coverage is an area, and areas add in light, so one rule covers text
  and everything else. Linear blending makes light text on a dark
  ground look thinner than the sRGB-byte blend did, so a theme sets
  the weight with a knob instead of a second rule.

## Proposed

- **A tag says what a buffer's pixels mean.** It is NeoVectra's three
  fields, carried on a Radharc surface and on a decoded image:
  - transfer: `srgb`, `linear`, `pq` or `hlg`;
  - primaries: `bt709` (sRGB's), `p3` or `bt2020`;
  - alpha: `opaque`, `premultiplied` or `straight`.

  An untagged buffer is `srgb bt709`, opaque unless its format has
  alpha, in which case it is premultiplied. In V5, Radharc composes
  only `srgb bt709` and refuses a surface tagged otherwise with a
  status that names the tag. The other transfers and primaries are
  converted once the display class gives each output its colour matrix
  from the EDID (step 6), and PQ and HLG once there is an HDR output.
  The codecs keep recording a file's `gAMA`, `sRGB` and `iCCP` without
  applying them, as todhchai's do. A decoder that can tell its image
  isn't sRGB tags it.
- **One tier 0 library holds the tables,** `Light` (`ui/light`).
  UICore's renderer, TextLayout's canvas and Radharc's composer all
  use it, so there is one rule and one place to change it.
  - Decoding is a 256-entry table from an sRGB byte to linear light in
    16 bits.
  - Encoding is a 4096-entry table from linear light in 12 bits back
    to a byte. It is exact to the byte for every byte that was
    decoded.
  - Tier 0 has no libm, so the tables are generated on the host and
    checked there against the sRGB formula.
  - Alpha is premultiplied in linear light.
  - An opaque copy, a fill with alpha 1 and an image drawn at 1:1
    don't touch the tables, so they stay exact and as fast as todhchai's.
- **What blends in light, and what doesn't.** These are blends of light
  and go through the tables:
  - compositing (alpha, coverage, a window's opacity);
  - scaling and filtering an image;
  - the steps of a gradient material.

  A theme's own `mix` of two colours is a colour pick, and it stays in
  sRGB, as CSS's `color-mix` defaults to (`Icons.swift`). It is
  resolved once, when the theme is, and is never drawn. The same goes
  for the WCAG contrast check, which already decodes to linear for
  luminance (`Color.swift`'s `srgbToLinear`). It is unchanged.
- **The contrast knob is `text.contrast`,** a D108 knob on the base
  theme: a curve applied to coverage before the blend, taken from a
  table of 256 entries per setting. Its default is chosen against the
  kit frame's pixel tests so that the base theme's body text matches
  todhchai's weight at 100%. A theme may set it, and so may the user's
  layers (D108), by workspace, output and app.
- **Theme colours stay sRGB hex** (D109's `0xrrggbb` and `0xrrggbbaa`).
  This entry replaces `docs/theming.md` §2.1's "colours are given in
  linear light with an SDR reference and an optional HDR peak in nits":
  the parser has nothing to convert. An HDR peak comes with the GPU
  step as an optional pair on a role (`peak=` in nits), used only on an
  HDR output and ignored on SDR. A theme written today needs no
  change then.
- **The output is assumed to be sRGB** until step 6. The GOP
  framebuffer and ramfb under edk2 carry no description of the
  display.
- **The pixel tests change once.** The kit frame's references and
  UICore's renderer tests are regenerated in the change that brings
  `Light` in. The diff they show is this decision's, and nothing else
  rides with it.
- **It costs no new budget.** The blend's cost shows up in the
  composition budgets V5 already has (`theme.compose.*`, the frame
  budgets), and a regression there is judged as any other.

## Left out

- FP16 composition, PQ and HLG output, and tone mapping: the GPU step,
  when there is an HDR output to drive.
- ICC profiles, calibration and wide-gamut conversion beyond the EDID's
  matrix (the roadmap's "out of scope").
- Dithering the encode's rounding: 12 bits of linear light in, 8 bits
  out, are judged by the pixel tests first.
