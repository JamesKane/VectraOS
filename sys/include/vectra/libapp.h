/*
vectra/libapp.h -- the platform layer for C, `docs/DEVTOOLS.md` section 4.

`sys/libapp` is written in Odin; this is the header a C program includes to call
it, one prototype per `proc "c"` the library exports. A C program links the Odin
package beside its own objects (the mixed image `tests/cmix` proves) and reaches
the library only through these.

The shape is Handmade Hero's: `vapp_run` once, then a loop of `vapp_frame`,
paint, `vapp_present` and `vapp_pump`, then `vapp_close`. `vapp_run` is first and
never returns -- it starts the Odin runtime and the scheduler and calls back into
the worker passed to it, because the frame loop runs inside a thread library and
the worker must run with the runtime live.

Hand-written, kept in step with `sys/libapp/capi.odin`. If `App` outgrows
`VAPP_SIZEOF` the Odin side's `#assert` fails the build before this drifts.
*/
#ifndef VECTRA_LIBAPP_H
#define VECTRA_LIBAPP_H

/* An `App` is opaque: a blob a program holds and passes by pointer, never looks
   inside. Sized to hold Odin's `App`, which `capi.odin` asserts fits. */
#define VAPP_SIZEOF 512
typedef struct {
	unsigned char _bytes[VAPP_SIZEOF];
} VApp;

/* A frame: the pixels to paint, the time since the last, and the pointer.
   `pixels[y * stride + x]`, for `x` under `width` and `y` under `height`. */
typedef struct {
	unsigned int *pixels;
	long          pixel_count;
	int           width;
	int           height;
	int           stride;
	float         dt;
	int           mouse_x;
	int           mouse_y;
	unsigned int  buttons;
	int           quit;
} VFrame;

/* Start the runtime and the scheduler, and call `fn(arg)` as the worker. Called
   once from `main`; never returns. */
void vapp_run(void (*fn)(void *arg), void *arg);

/* Claim a window `w` by `h`, name it `title`, and attach its store. Nonzero on
   success. Call only from inside the worker `vapp_run` started. */
int vapp_open(VApp *app, const char *title, int w, int h);

/* Drain the input and hand back this turn's pixels and pointer, through `out`. */
void vapp_frame(VApp *app, VFrame *out);

/* Composite what was painted. `vsync` is taken for the loop's shape. */
void vapp_present(VApp *app, int vsync);

/* Hand `count` interleaved signed-16-bit samples to the device (two to a
   stereo frame), and return how many it took. */
int vapp_sound(VApp *app, short *samples, int count);

/* The device's rate in samples a second, and channels a frame -- the shape a
   program's samples must take. Zero rate is a machine with no card. */
int vapp_rate(VApp *app);
int vapp_channels(VApp *app);

/* Yield to the pointer thread: a busy frame loop yields nowhere else. */
void vapp_pump(VApp *app);

/* Give the window and its store back. */
void vapp_close(VApp *app);

/* End the program, every thread of it: how a worker that is done, or one that
   could not open a window, leaves. */
void vapp_threadexitsall(void);

#endif /* VECTRA_LIBAPP_H */
