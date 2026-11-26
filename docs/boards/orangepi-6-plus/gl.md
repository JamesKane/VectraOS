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

## The shaders glmark2 compiles

`MESA_SHADER_DUMP_PATH` on the same run, every scene at 0.3 s: 69 distinct
sources, 29 vertex and 40 fragment, all GLSL ES 1.00 (glmark2's are GPLv3,
so they stay out of the tree, in `.cache/ports/glmark2-shaders`, for the
GLSL front end's corpus test).
