# Orange Pi 6 Plus: OpenGL ES and glmark2 (D183)

## The reference: AbyssBSD's Panfrost, 2026-11-26

What our GL is judged against (D183: each scene's limit is 98% of these).
AbyssBSD's FreeBSD on this board (`orangepi-6-plus-f12c9f4ee6e3`, 16.0-CURRENT),
panthor with its devfreq (the GPU at 1000 MHz under load), Mesa 26.2.2's
Panfrost (`Mali-G720 MC10 (Panfrost)`, OpenGL ES 3.1), glmark2 2023.01 from
ports. Run over ssh with nothing else on the GPU:

    cpuset -l "$(bigcores)" glmark2-es2-gbm --off-screen -s 800x600

Off-screen, glmark2 ends every frame with `glFinish`, so a frame is a whole
round trip, CPU to GPU and back. Surface: RGBA8888, depth 32, no stencil, no
multisampling.

| Scene | FPS | Frame (ms) |
|---|---:|---:|
| build use-vbo=false | 1610 | 0.621 |
| build use-vbo=true | 3523 | 0.284 |
| texture texture-filter=nearest | 4887 | 0.205 |
| texture texture-filter=linear | 4925 | 0.203 |
| texture texture-filter=mipmap | 4892 | 0.204 |
| shading shading=gouraud | 2223 | 0.450 |
| shading shading=blinn-phong-inf | 2212 | 0.452 |
| shading shading=phong | 1560 | 0.641 |
| shading shading=cel | 1541 | 0.649 |
| bump bump-render=high-poly | 892 | 1.121 |
| bump bump-render=normals | 5506 | 0.182 |
| bump bump-render=height | 4782 | 0.209 |
| effect2d kernel=0,1,0;1,-4,1;0,1,0; | 5678 | 0.176 |
| effect2d kernel=1,1,1,1,1;1,1,1,1,1;1,1,1,1,1; | 4091 | 0.244 |
| pulsar light=false:quads=5:texture=false | 4742 | 0.211 |
| desktop blur-radius=5:effect=blur:passes=1:separable=true:windows=4 | 753 | 1.329 |
| desktop effect=shadow:windows=4 | 2256 | 0.443 |
| buffer columns=200:interleave=false:update-dispersion=0.9:update-fraction=0.5:update-method=map | 400 | 2.506 |
| buffer columns=200:interleave=false:update-dispersion=0.9:update-fraction=0.5:update-method=subdata | 391 | 2.558 |
| buffer columns=200:interleave=true:update-dispersion=0.9:update-fraction=0.5:update-method=map | 431 | 2.323 |
| ideas speed=duration | 973 | 1.028 |
| jellyfish <default> | 2615 | 0.383 |
| terrain <default> | 95 | 10.540 |
| shadow <default> | 1749 | 0.572 |
| refract <default> | 149 | 6.750 |
| conditionals fragment-steps=0:vertex-steps=0 | 4877 | 0.205 |
| conditionals fragment-steps=5:vertex-steps=0 | 4718 | 0.212 |
| conditionals fragment-steps=0:vertex-steps=5 | 4925 | 0.203 |
| function fragment-complexity=low:fragment-steps=5 | 4752 | 0.210 |
| function fragment-complexity=medium:fragment-steps=5 | 4584 | 0.218 |
| loop fragment-loop=false:fragment-steps=5:vertex-steps=5 | 4901 | 0.204 |
| loop fragment-steps=5:fragment-uniform=false:vertex-steps=5 | 4810 | 0.208 |
| loop fragment-steps=5:fragment-uniform=true:vertex-steps=5 | 4713 | 0.212 |

glmark2 score: **3064**.

A second run with every scene shortened to 0.3 s (the shader dump below)
scored 2,992; the full run's numbers are the reference.

Windowed, 800x600 under sway on the big cores (the owner's screenshot,
FreeBSD 15.1 with Mesa 26.2.2): jellyfish 4,029 to 4,161 FPS, about 4,100,
ending frames by swaps, not `glFinish`.

## Ours: the first run, 2026-11-26 (gl at 32939ecf)

`esp-board-glmark2`: glmark2 off-screen at 800x600 over our GLES on the
core's Mali backend, on whatever core the scheduler gives it (no pinning
yet). The ratio is ours over the reference; the target is 0.98.

| Scene | Reference | Ours | Ratio |
|---|---:|---:|---:|
| build use-vbo=false | 1610 | 1705 | 1.06 |
| build use-vbo=true | 3523 | 2678 | 0.76 |
| texture nearest | 4887 | 3242 | 0.66 |
| texture linear | 4925 | 3181 | 0.65 |
| texture mipmap | 4892 | 3208 | 0.66 |
| shading gouraud | 2223 | 2115 | 0.95 |
| shading blinn-phong-inf | 2212 | 2209 | 1.00 |
| shading phong | 1560 | 1942 | 1.24 |
| shading cel | 1541 | 1937 | 1.26 |
| bump high-poly | 892 | 1152 | 1.29 |
| bump normals | 5506 | 3494 | 0.63 |
| bump height | 4782 | 3263 | 0.68 |
| effect2d 3x3 | 5678 | 3134 | 0.55 |
| effect2d 5x3 | 4091 | 2640 | 0.65 |
| pulsar | 4742 | 3436 | 0.72 |
| desktop blur | 753 | 96 | 0.13 |
| desktop shadow | 2256 | 107 | 0.05 |
| buffer map | 400 | 990 | 2.48 |
| buffer subdata | 391 | 989 | 2.53 |
| buffer interleaved map | 431 | 1150 | 2.67 |
| ideas | 973 | 423 | 0.43 |
| jellyfish | 2615 | 1610 | 0.62 |
| terrain | 95 | unsupported | |
| shadow | 1749 | glmark2 killed (-1028) | |

The rest did not run. What it shows:

- **A floor of about 0.31 ms a frame** holds the light scenes near 3,200
  FPS where Panfrost does 0.18 to 0.21 ms. The core's own frame budgets
  put an 800x600 clear and draw at 122 us of GPU time against 66 us for
  64x64: the frame's write-back, uncompressed, where Panfrost's render
  targets are AFBC; then about 48 us of CPU before the GPU starts and 25
  us to wake the waiting thread.
- **desktop** is about 10 ms a frame: it draws each window into a
  framebuffer of its own and samples it, many passes a frame, so
  something is paid per pass far beyond a pass's GPU cost.
- **ideas** is many draws a frame: the per-draw CPU cost.
- **terrain**: GL reports `GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS` 0 though
  the backend now samples in the vertex stage.
- The heavy scenes (phong, cel, high-poly, buffer) beat the reference.

## The compiler, 2026-11-26 (gl after 23a80838)

effect2d was compute-bound in our own code: the 3x3 kernel's fragment
shader was about 200 instructions (nine taps, five of them zero; the
combined image sampler's handle words loaded again for every tap; each
weight made again for each channel). Folding `x * 0`, merging equal loads
of a block, contracting products into fused multiply-adds, and making a
constant and a handle pair once a block brought it to 63. Graphics
shaders were then all class 64; 37 of glmark2's 39 fragment shaders fit
class 32, twice the resident threads. A subset run on the board (FPS):

| Scene | Reference | Before | Folds | Class 32 | Ratio |
|---|---:|---:|---:|---:|---:|
| effect2d 3x3 | 5678 | 3717 | 6181 | 6199 | 1.09 |
| effect2d 5x3 | 4091 | 2779 | 3892 | 4481 | 1.10 |
| texture | 4925 | 4973 | 4924 | 5297 | 1.08 |
| pulsar | 4742 | 4636 | 4582 | 5078 | 1.07 |
| bump normals | 5506 | 6343 | 6278 | 6540 | 1.19 |
| desktop shadow | 2256 | | 1281 | 1294 | 0.57 |
| ideas | 973 | | 429 | 441 | 0.45 |
| jellyfish | 2615 | | 1721 | 1860 | 0.71 |

"Before" for effect2d 5x3 is after the zero fold alone (it has no zero
weights). desktop and ideas are bound by the per-pass and per-draw costs,
not by their shaders.

## Every scene, 2026-11-27 (gl at 2a1bca96)

The full off-screen run at 800x600 (`esp-board-glmark2`), with GL's
per-frame work (AFBC for images GL only draws and samples, mipmaps drawn,
loads and stores only what a pass's draws use, about 450 ns a draw), the
shaders' work (vertex shaders divided between the IDVS passes, loads sunk
and combined, private variables in registers) and the Mali submit's
(draw state shared within a pass, register deltas, one-way posts).
**glmark2 Score: 4397**, against the reference's 3064 (1.44).

| Scene | Reference | Ours | Ratio |
|---|---:|---:|---:|
| build use-vbo=false | 1610 | 2605 | 1.62 |
| build use-vbo=true | 3523 | 5934 | 1.68 |
| texture nearest | 4887 | 5803 | 1.19 |
| texture linear | 4925 | 5734 | 1.16 |
| texture mipmap | 4892 | 5958 | 1.22 |
| shading gouraud | 2223 | 4565 | 2.05 |
| shading blinn-phong-inf | 2212 | 4491 | 2.03 |
| shading phong | 1560 | 3498 | 2.24 |
| shading cel | 1541 | 3576 | 2.32 |
| bump high-poly | 892 | 2314 | 2.59 |
| bump normals | 5506 | 7424 | 1.35 |
| bump height | 4782 | 6700 | 1.40 |
| effect2d 3x3 | 5678 | 6254 | 1.10 |
| effect2d 5x3 | 4091 | 4595 | 1.12 |
| pulsar | 4742 | 6092 | 1.28 |
| desktop blur | 753 | 1020 | 1.35 |
| desktop shadow | 2256 | 2161 | **0.96** |
| buffer map | 400 | 1279 | 3.20 |
| buffer subdata | 391 | 1264 | 3.23 |
| buffer interleaved map | 431 | 1712 | 3.97 |
| ideas | 973 | 720 | **0.74** |
| jellyfish | 2615 | 3021 | 1.16 |
| terrain | 95 | 117 | 1.23 |
| shadow | 1749 | 1968 | 1.13 |
| refract | 149 | 156 | 1.05 |
| conditionals (three) | 4718-4925 | 6430-7216 | 1.36-1.48 |
| function (two) | 4584-4752 | 7151-7165 | 1.51-1.56 |
| loop (three) | 4713-4901 | 6921-7122 | 1.45-1.47 |

ideas (227 draws a frame) is still bound by the submit's CPU cost, and
desktop shadow (many small passes) by the fixed cost of a pass.

## The submit and the pass, 2026-11-27 (pass-cost after gl 2a1bca96)

ideas (227 to 353 draws in one pass) was bound by the CPU's submit: about 550 us a frame for 227 draws (plan 205, recipe
242). A draw's state is now shared by the draws of a pipeline and read once a run of them, a run's registers are written only
where they differ, and the reads of a draw's shared fields from outside MaliCore (each allocated its accessor's frame) are
gone: the same frame's submit is about 360 us. A pass is then one stream on one queue, its tiling and then its fragment
work, where it was a stream on each of two queues with a sync object between: on the board that starts the work sooner,
tiles sooner and needs no wait between queues (loinnir-test's stamps: 53 us of stream for a clear and one draw on two
queues, 37 on one). The full run (FPS):

| Scene | Reference | Before | After | Ratio |
|---|---:|---:|---:|---:|
| ideas | 973 | 720 | 878 | 0.90 |
| desktop shadow | 2256 | 2161 | 2438 | 1.08 |
| desktop blur | 753 | 1020 | 1116 | 1.48 |
| jellyfish | 2615 | 3021 | 3119 | 1.19 |
| shadow | 1749 | 1968 | 2083 | 1.19 |
| glmark2 score | 3064 | 4397 | 4712 | 1.54 |

Every other scene rose 1 to 10 percent. ideas alone, twice in one run, gave 902 and 908 (and 984 in a run with GLES_STATS):
the scene is the CPU's, and the core the scheduler gives it moves it by several percent. Its frame is then about 300 us of
GL's recording, 360 of the submit and 130 of waiting.

## The shaders glmark2 compiles

`MESA_SHADER_DUMP_PATH` on the same run, every scene at 0.3 s: 69 distinct
sources, 29 vertex and 40 fragment, all GLSL ES 1.00 (glmark2's are GPLv3,
so they stay out of the tree, in `.cache/ports/glmark2-shaders`, for the
GLSL front end's corpus test).
