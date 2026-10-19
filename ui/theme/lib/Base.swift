// SPDX-License-Identifier: BSD-3-Clause

// The system's base theme (theming.md §2.7): the root of every chain. It
// resolves every required role and the kit's parts plainly, so a theme
// that defines one role still draws everything, and its high-contrast
// variant is the system's derivation for a theme without one. Compiled in,
// so that resolving never lacks a root.

let baseTheme = """
  # The system's base theme (ui/theme/lib/Base.swift; theme(6)).
  theme=base title="System base" version=1 author="VectraOS" licence=BSD-3-Clause

  # Surfaces.
  role=desk color=0xc4c9d2
  role=chrome color=0xe4e4e4
  role=chrome.behind color=0xd2d2d2
  role=well color=0xffffff
  role=menu color=0xf0f0f0
  role=panel color=0xeaeaea
  # Edges: control is a control's edge, at least 3:1 against the surfaces.
  role=outline color=0x7c7c7c
  role=bevel.light color=0xffffff
  role=bevel.dark color=0x8c8c8c
  role=control color=0x6a6a6a
  # Ink.
  role=ink color=0x000000
  role=ink.dim color=0x4f4f4f
  role=ink.disabled color=0x8e8e8e
  role=ink.on-select color=0xffffff
  role=ink.on-focus color=0xffffff
  # Meanings: focus and selection stay distinct.
  role=focus color=0x1d4fc4
  role=selection color=0x2b56b8
  role=live color=0x17703a
  role=alert color=0xb0261c
  role=warning color=0x865400
  role=realtime color=0x6a3c9e
  # Readouts and lamps.
  role=lcd color=0x1c261c
  role=lcd.ink color=0xb6eeb6
  role=lamp.local color=0x17703a
  role=lamp.agent color=0x6a3c9e
  role=lamp.egress color=0xb0261c
  role=lamp.swarm color=0x1d4fc4
  # rio's and vt's sixteen colours: VGA's, as most terminals start.
  role=term.0 color=0x000000
  role=term.1 color=0xaa0000
  role=term.2 color=0x00aa00
  role=term.3 color=0xaa5500
  role=term.4 color=0x0000aa
  role=term.5 color=0xaa00aa
  role=term.6 color=0x00aaaa
  role=term.7 color=0xaaaaaa
  role=term.8 color=0x555555
  role=term.9 color=0xff5555
  role=term.10 color=0x55ff55
  role=term.11 color=0xffff55
  role=term.12 color=0x5555ff
  role=term.13 color=0xff55ff
  role=term.14 color=0x55ffff
  role=term.15 color=0xffffff

  typeface=display family="IBM Plex Sans" weight=600
  typeface=body family="IBM Plex Sans" weight=400
  typeface=mono family="IBM Plex Mono" weight=400
  typeface=ui family="IBM Plex Sans" weight=500

  # Text is blended in linear light, which draws ink thinner than blending
  # the bytes did on a lighter ground, and bolder on a darker one; this
  # curve gives text its weight back (light(2)).
  knob=text.contrast type=scale default=0.6 min=0 max=1 label="Text contrast"

  # The kit's parts, plainly: flat fills, one-pixel edges.
  part=default fill=desk ink=ink
  part=desktop fill=desk ink=ink
  part=desktop.icon.selected glowcolor=focus@55
  part=window.tab fill=chrome.behind stroke=outline ink=ink.dim border=1
  	weight=600 padding=4,16,4,8
  part=window.tab.focused fill=chrome ink=ink
  part=window.body fill=chrome stroke=outline border=1
  part=window.body.focused stroke=control
  part=button fill=chrome stroke=control border=1 weight=600 padding=5,12,5,12
  part=button.primary stroke=focus border=2
  part=button.danger stroke=alert ink=alert
  part=toggle fill=chrome stroke=control border=1 weight=600 padding=5,12,5,12
  part=toggle.on fill=selection ink=ink.on-select
  part=field fill=well stroke=control border=1 font=mono weight=400 padding=4,6,4,6
  part=field.focused stroke=focus
  part=field.caret fill=ink
  part=field.selection fill=selection ink=ink.on-select
  part=label fill=none
  part=label.dim ink=ink.dim
  part=label.link ink=focus
  part=text fill=none font=body weight=400 size=15 lineheight=1.6
  part=heading fill=none font=display weight=700 size=24 lineheight=1.15
  part=menu fill=menu stroke=outline border=1
  part=menu.item fill=none padding=4,10,4,10
  part=menu.item.hot fill=selection ink=ink.on-select
  part=menu.item.dimmed ink=ink.disabled
  part=scrollbar fill=chrome.behind stroke=outline border=1
  part=scrollbar.thumb fill=chrome stroke=control
  part=table fill=well font=mono weight=400
  part=table.header fill=chrome ink=ink.dim weight=600
  part=table.row.selected fill=selection ink=ink.on-select
  part=focus fill=none stroke=focus border=2
  part=panel fill=panel stroke=outline border=1 padding=10,10,10,10
  part=deskbar fill=chrome stroke=outline border=1
  part=status fill=chrome stroke=outline ink=ink.dim border=1 font=mono weight=400

  # High contrast (theming.md §6): every theme's, unless it has its own.
  variant=high-contrast title="High contrast"
  	role=desk color=0x000000
  	role=chrome color=0x000000
  	role=chrome.behind color=0x000000
  	role=well color=0x000000
  	role=menu color=0x000000
  	role=panel color=0x000000
  	role=outline color=0xffffff
  	role=control color=0xffffff
  	role=ink color=0xffffff
  	role=ink.dim color=0xffffff
  	role=ink.disabled color=0x9a9a9a
  	role=focus color=0xffff00
  	role=selection color=0x00ffff
  	role=ink.on-select color=0x000000
  	role=ink.on-focus color=0x000000
  	role=live color=0x00ff00
  	role=alert color=0xff6060
  	role=warning color=0xffbf00
  	role=realtime color=0xff80ff
  	role=lamp.local color=0x00ff00
  	role=lamp.agent color=0xff80ff
  	role=lamp.egress color=0xff6060
  	role=lamp.swarm color=0x40c0ff
  	textscale=1.25
  """
