/*
capp -- a `sys/libapp` client in C, `docs/DEVTOOLS.md` step 2.

The C face of `apptest`, the same program in the other language: it opens a
window and each frame fills the client area a ground colour and paints a marker
square where the pointer is, then presents. It runs until its window closes under
it, or a safety cap, then closes and exits. The self-test drives it exactly as it
drives the Odin one -- reading the ground and the marker out of the store -- so a
header a C program cannot link against, or a library it cannot call, fails the
boot.

`main` calls `vapp_run` and nothing else: the loop runs in the worker, on a
thread with the Odin runtime live, because the library is a thread program
inside.
*/
#include <vectra/libapp.h>

#define GROUND 0x00224466u
#define MARKER 0x00EE8822u
#define MARK_SZ 16
#define MARK_OFF 28
#define MAX_FRAMES 20000

static VApp app;

static int clampi(int v, int lo, int hi)
{
	if (v < lo) return lo;
	if (v > hi) return hi;
	return v;
}

static void worker(void *arg)
{
	(void)arg;
	if (!vapp_open(&app, "capp", 360, 240)) {
		vapp_threadexitsall();
	}

	/* A short tone through libapp, so the self-test sees samples reach the
	   device from C too: a square wave, interleaved, in chunks. */
	short chunk[960]; /* 480 stereo frames */
	int phase = 0;
	for (int played = 0; played < 9600; played += 480) {
		for (int i = 0; i < 480; i++) {
			short v = (phase / 60) % 2 == 0 ? 6000 : -6000;
			chunk[i * 2] = v;
			chunk[i * 2 + 1] = v;
			phase++;
		}
		vapp_sound(&app, chunk, 960);
	}

	for (int i = 0; i < MAX_FRAMES; i++) {
		VFrame f;
		vapp_frame(&app, &f);

		/* The ground, every frame, so the marker's last place is rubbed out. */
		for (int y = 0; y < f.height; y++) {
			unsigned int *row = f.pixels + (long)y * f.stride;
			for (int x = 0; x < f.width; x++) {
				row[x] = GROUND;
			}
		}

		/* The marker down-right of the pointer, clamped to the client area. */
		int mxlim = f.width - MARK_SZ > 0 ? f.width - MARK_SZ : 0;
		int mylim = f.height - MARK_SZ > 0 ? f.height - MARK_SZ : 0;
		int mx = clampi(f.mouse_x + MARK_OFF, 0, mxlim);
		int my = clampi(f.mouse_y + MARK_OFF, 0, mylim);
		for (int y = 0; y < MARK_SZ; y++) {
			unsigned int *row = f.pixels + (long)(my + y) * f.stride;
			for (int x = 0; x < MARK_SZ; x++) {
				row[mx + x] = MARKER;
			}
		}

		vapp_present(&app, 1);
		if (f.quit) {
			break;
		}
		vapp_pump(&app);
	}

	vapp_close(&app);
	vapp_threadexitsall();
}

int main(void)
{
	vapp_run(worker, 0); /* Never returns. */
	return 0;
}
