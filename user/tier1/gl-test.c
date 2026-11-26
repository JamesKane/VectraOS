// SPDX-License-Identifier: BSD-3-Clause

// gl-test (gl-test(8), D183): OpenGL ES 2.0 and EGL in C, as a port uses them: linked against libEGL.so and
// libGLESv2.so, whose names reach libGLES.so (gles(3), egl(3)). C because that is GL's interface. On a 64 by 64
// RGBA8888 pbuffer with depth it checks, reading back with glReadPixels:
//   - a clear;
//   - a triangle from a vertex buffer in a uniform colour, exact inside and outside, edges not judged;
//   - a textured quad: an RGB texture (nearest) and an RGBA one whose mipmaps glGenerateMipmap made, read at level 1;
//   - the depth test: the nearer of two triangles drawn first is all that shows;
//   - blending: half-transparent white over black, within 1;
//   - render to texture: a framebuffer object's texture drawn into, then sampled by a second pass;
//   - 20 draws in a frame, more than a pass of the Mali backend takes, each its own column;
//   - client-side arrays: positions as floats and colours as normalized bytes from the program's memory;
// and on a window of Radharc's, where there is a compositor: frames swapped at interval 1 and at 0.
// Then the budgets: `gl.frame_us.empty` (a clear and glFinish) and `gl.frame_us.draw` (a clear, one draw and
// glFinish), each the median of 200 frames. It prints `gl-test: ok: gl NAME` for each check that passed and exits 0
// only if all did. Its shaders are user/tier1/gl-shaders' SPIR-V (vx shaders makes shaders.h), given to
// glShaderBinary: the library's GLSL front end is another's.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include "shaders.h"

#define SIZE 64
#define GL_SHADER_BINARY_FORMAT_SPIR_V 0x9551

static int failures;

static void fail(const char *what) {
  printf("gl-test: FAILED: %s\n", what);
  failures++;
}

static int check_gl(const char *where) {
  GLenum e = glGetError();
  if (e == GL_NO_ERROR) return 1;
  printf("gl-test: FAILED: %s: GL error 0x%04x\n", where, e);
  failures++;
  return 0;
}

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

/// A program of two of gl-shaders' modules, given as SPIR-V binaries.
static GLuint program(const uint32_t *vs, size_t vs_bytes, const uint32_t *fs, size_t fs_bytes) {
  GLuint p = glCreateProgram();
  GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER);
  glShaderBinary(1, &v, GL_SHADER_BINARY_FORMAT_SPIR_V, vs, (GLsizei)vs_bytes);
  glShaderBinary(1, &f, GL_SHADER_BINARY_FORMAT_SPIR_V, fs, (GLsizei)fs_bytes);
  glAttachShader(p, v);
  glAttachShader(p, f);
  glLinkProgram(p);
  GLint linked = 0;
  glGetProgramiv(p, GL_LINK_STATUS, &linked);
  if (!linked) {
    char log[512] = {0};
    glGetProgramInfoLog(p, sizeof log, NULL, log);
    printf("gl-test: FAILED: a program didn't link: %s\n", log);
    failures++;
  }
  glDeleteShader(v);
  glDeleteShader(f);
  return p;
}

#define PROGRAM(v, f) program(v, sizeof v, f, sizeof f)

/// The transform (x and y scaled, then moved) and the colour of the flat and textured programs.
static void uniforms(GLuint p, float sx, float sy, float tx, float ty, float r, float g, float b, float a) {
  glUseProgram(p);
  glUniform4f(glGetUniformLocation(p, "transform"), sx, sy, tx, ty);
  glUniform4f(glGetUniformLocation(p, "color"), r, g, b, a);
}

static uint8_t pixels[SIZE * SIZE * 4];

static void read_all(void) { glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, pixels); }

static const uint8_t *at(int x, int y) { return pixels + 4 * (y * SIZE + x); }

static int near(const uint8_t *got, const uint8_t *want, int slack) {
  for (int k = 0; k < 4; k++) {
    int d = (int)got[k] - (int)want[k];
    if (d < -slack || d > slack) return 0;
  }
  return 1;
}

/// Judges every pixel against `want(x, y)` (NULL: not judged), within `slack`: the count wrong, the first few printed.
static int judge(const char *name, const uint8_t *(*want)(int x, int y), int slack) {
  read_all();
  int wrong = 0, judged = 0;
  for (int y = 0; y < SIZE; y++) {
    for (int x = 0; x < SIZE; x++) {
      const uint8_t *w = want(x, y);
      if (!w) continue;
      judged++;
      if (!near(at(x, y), w, slack)) {
        if (wrong < 4) {
          const uint8_t *g = at(x, y);
          printf("gl-test: %s: pixel %d, %d is %02x%02x%02x%02x, not %02x%02x%02x%02x\n", name, x, y, g[0], g[1], g[2], g[3], w[0],
                 w[1], w[2], w[3]);
        }
        wrong++;
      }
    }
  }
  printf("gl-test: %s: %d pixels judged, %d wrong\n", name, judged, wrong);
  return wrong == 0 && judged > 0;
}

static const uint8_t red[4] = {255, 0, 0, 255}, green[4] = {0, 255, 0, 255}, blue[4] = {0, 0, 255, 255};
static const uint8_t black[4] = {0, 0, 0, 255}, white[4] = {255, 255, 255, 255}, grey[4] = {128, 128, 128, 255};
static const uint8_t yellow[4] = {255, 255, 0, 255};

static GLuint flat, textured, shaded;
static GLuint full_buffer;

/// A triangle that covers the whole target, at depth `z`, from the vertex buffer at attribute 0.
static void bind_full(void) {
  glBindBuffer(GL_ARRAY_BUFFER, full_buffer);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);
  glEnableVertexAttribArray(0);
}

static const uint8_t *want_red(int x, int y) { (void)x, (void)y; return red; }

static void test_clear(void) {
  glClearColor(1, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  if (judge("clear", want_red, 0) && check_gl("clear")) printf("gl-test: ok: gl clear\n");
}

// The lower-left half: x + y below SIZE, edges (within a pixel of the diagonal) not judged.
static const uint8_t *want_triangle(int x, int y) {
  int s = x + y;
  if (s <= SIZE - 3) return green;
  if (s >= SIZE + 1) return black;
  return NULL;
}

static void test_triangle(void) {
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  static const float tri[] = {-1, -1, 0, 1, 1, -1, 0, 1, -1, 1, 0, 1};
  GLuint b;
  glGenBuffers(1, &b);
  glBindBuffer(GL_ARRAY_BUFFER, b);
  glBufferData(GL_ARRAY_BUFFER, sizeof tri, tri, GL_STATIC_DRAW);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 16, 0);
  glEnableVertexAttribArray(0);
  uniforms(flat, 1, 1, 0, 0, 0, 1, 0, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  if (judge("triangle", want_triangle, 0) && check_gl("triangle")) printf("gl-test: ok: gl triangle\n");
  glDeleteBuffers(1, &b);
}

// The RGB texture's four texels, one a quadrant, drawn over the whole target with nearest filtering.
static const uint8_t *want_rgb(int x, int y) {
  static const uint8_t q[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}};
  if (x == SIZE / 2 - 1 || x == SIZE / 2 || y == SIZE / 2 - 1 || y == SIZE / 2) return NULL;
  return q[(y >= SIZE / 2) * 2 + (x >= SIZE / 2)];
}

static GLuint quad_buffer;

/// A quad over the whole target, positions at attribute 0 and texture coordinates at 1, as a strip.
static void bind_quad(void) {
  glBindBuffer(GL_ARRAY_BUFFER, quad_buffer);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 24, 0);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 24, (const void *)16);
  glEnableVertexAttribArray(0);
  glEnableVertexAttribArray(1);
}

static void test_texture(void) {
  // RGB, two by two, rows of 6 bytes padded to 8 by the unpack alignment.
  static const uint8_t rgb[] = {255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 255, 255, 255, 0, 0, 0};
  GLuint t[2];
  glGenTextures(2, t);
  glBindTexture(GL_TEXTURE_2D, t[0]);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 2, 2, 0, GL_RGB, GL_UNSIGNED_BYTE, rgb);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  uniforms(textured, 1, 1, 0, 0, 1, 1, 1, 1);
  bind_quad();
  glClear(GL_COLOR_BUFFER_BIT);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  int ok = judge("texture rgb", want_rgb, 0);
  // RGBA, four by four, each quadrant one colour: level 1 is the four colours, read by a 2 by 2 viewport at the
  // nearest mip level.
  uint8_t rgba[4 * 4 * 4];
  for (int y = 0; y < 4; y++)
    for (int x = 0; x < 4; x++) {
      const uint8_t *c = y < 2 ? (x < 2 ? red : green) : (x < 2 ? blue : yellow);
      memcpy(rgba + 4 * (y * 4 + x), c, 4);
    }
  glBindTexture(GL_TEXTURE_2D, t[1]);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
  glGenerateMipmap(GL_TEXTURE_2D);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glViewport(0, 0, 2, 2);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glViewport(0, 0, SIZE, SIZE);
  read_all();
  const uint8_t *want[4] = {red, green, blue, yellow};
  for (int i = 0; i < 4; i++) {
    const uint8_t *g = at(i % 2, i / 2);
    if (!near(g, want[i], 1)) {
      printf("gl-test: texture mipmap: pixel %d, %d is %02x%02x%02x%02x\n", i % 2, i / 2, g[0], g[1], g[2], g[3]);
      ok = 0;
    }
  }
  if (!near(at(4, 4), black, 0)) ok = 0;
  if (ok && check_gl("texture")) printf("gl-test: ok: gl texture\n");
  glDeleteTextures(2, t);
  glDisableVertexAttribArray(1);
}

static void test_depth(void) {
  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LESS);
  glClearColor(0, 0, 0, 1);
  glClearDepthf(1);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  bind_full();
  // The nearer (z -0.5, GL's clip space) first, red; then the farther (z 0.5), blue: the depth test keeps red.
  static const float near_tri[] = {-1, -1, -0.5f, 1, 3, -1, -0.5f, 1, -1, 3, -0.5f, 1};
  static const float far_tri[] = {-1, -1, 0.5f, 1, 3, -1, 0.5f, 1, -1, 3, 0.5f, 1};
  GLuint b[2];
  glGenBuffers(2, b);
  glBindBuffer(GL_ARRAY_BUFFER, b[0]);
  glBufferData(GL_ARRAY_BUFFER, sizeof near_tri, near_tri, GL_STATIC_DRAW);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);
  uniforms(flat, 1, 1, 0, 0, 1, 0, 0, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glBindBuffer(GL_ARRAY_BUFFER, b[1]);
  glBufferData(GL_ARRAY_BUFFER, sizeof far_tri, far_tri, GL_STATIC_DRAW);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);
  uniforms(flat, 1, 1, 0, 0, 0, 0, 1, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glDisable(GL_DEPTH_TEST);
  if (judge("depth", want_red, 0) && check_gl("depth")) printf("gl-test: ok: gl depth\n");
  glDeleteBuffers(2, b);
}

static const uint8_t *want_grey(int x, int y) { (void)x, (void)y; return grey; }

static void test_blend(void) {
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glEnable(GL_BLEND);
  glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
  bind_full();
  uniforms(flat, 1, 1, 0, 0, 1, 1, 1, 0.5f);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glDisable(GL_BLEND);
  if (judge("blend", want_grey, 1) && check_gl("blend")) printf("gl-test: ok: gl blend\n");
}

// The texture drawn: blue, with a green lower-left triangle (as test_triangle's), sampled over the whole target.
static const uint8_t *want_rtt(int x, int y) {
  int s = x + y;
  if (s <= SIZE - 6) return green;
  if (s >= SIZE + 4) return blue;
  return NULL;
}

static void test_render_to_texture(void) {
  GLuint t, f;
  glGenTextures(1, &t);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 32, 32, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glGenFramebuffers(1, &f);
  glBindFramebuffer(GL_FRAMEBUFFER, f);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) fail("render to texture: the framebuffer isn't complete");
  glViewport(0, 0, 32, 32);
  glClearColor(0, 0, 1, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  static const float tri[] = {-1, -1, 0, 1, 1, -1, 0, 1, -1, 1, 0, 1};
  GLuint b;
  glGenBuffers(1, &b);
  glBindBuffer(GL_ARRAY_BUFFER, b);
  glBufferData(GL_ARRAY_BUFFER, sizeof tri, tri, GL_STATIC_DRAW);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);
  glEnableVertexAttribArray(0);
  uniforms(flat, 1, 1, 0, 0, 0, 1, 0, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  // The second pass, into the pbuffer, samples it.
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, SIZE, SIZE);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  uniforms(textured, 1, 1, 0, 0, 1, 1, 1, 1);
  bind_quad();
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  if (judge("render to texture", want_rtt, 0) && check_gl("render to texture")) printf("gl-test: ok: gl render to texture\n");
  glDisableVertexAttribArray(1);
  glDeleteFramebuffers(1, &f);
  glDeleteTextures(1, &t);
  glDeleteBuffers(1, &b);
}

#define COLUMNS 20

// Column i (SIZE / COLUMNS wide, a pixel of margin) is grey level i * 12.
static const uint8_t *want_columns(int x, int y) {
  static uint8_t level[4];
  (void)y;
  int w = SIZE / COLUMNS;
  int i = x / w;
  if (i >= COLUMNS || x % w == 0 || x % w == w - 1) return NULL;
  level[0] = level[1] = level[2] = (uint8_t)(i * 12);
  level[3] = 255;
  return level;
}

static void test_many_draws(void) {
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  // The unit square of the quad's buffer, scaled to a column and moved to its place.
  bind_quad();
  float w = 2.0f * (SIZE / COLUMNS) / SIZE;
  for (int i = 0; i < COLUMNS; i++) {
    float level = (float)(i * 12) / 255.0f;
    uniforms(flat, w / 2, 1, -1 + w * i + w / 2, 0, level, level, level, 1);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  }
  glDisableVertexAttribArray(1);
  if (judge("many draws", want_columns, 1) && check_gl("many draws")) printf("gl-test: ok: gl many draws\n");
}

// The lower-left half as test_triangle's, in the colour of its vertices (all red).
static const uint8_t *want_client(int x, int y) {
  int s = x + y;
  if (s <= SIZE - 3) return red;
  if (s >= SIZE + 1) return black;
  return NULL;
}

static void test_client_arrays(void) {
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  // A vertex before the first drawn, to see that the first is where DrawArrays begins.
  static const float positions[] = {9, 9, 9, 1, -1, -1, 0, 1, 1, -1, 0, 1, -1, 1, 0, 1};
  static const uint8_t colors[] = {0, 0, 255, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255};
  glUseProgram(shaded);
  glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, positions);
  glVertexAttribPointer(1, 4, GL_UNSIGNED_BYTE, GL_TRUE, 0, colors);
  glEnableVertexAttribArray(0);
  glEnableVertexAttribArray(1);
  glDrawArrays(GL_TRIANGLES, 1, 3);
  glDisableVertexAttribArray(1);
  if (judge("client arrays", want_client, 0) && check_gl("client arrays")) printf("gl-test: ok: gl client arrays\n");
}

static int compare(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}

/// The median of 200 frames' times in microseconds: `draw` 0, a clear and glFinish; 1, a clear, a draw and glFinish.
static uint64_t frame_us(int draw) {
  enum { FRAMES = 200 };
  static uint64_t t[FRAMES];
  uniforms(flat, 1, 1, 0, 0, 0, 1, 0, 1);
  bind_full();
  for (int i = 0; i < FRAMES + 10; i++) {
    uint64_t start = now_ns();
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    if (draw) glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();
    // The first ten make what the frame needs.
    if (i >= 10) t[i - 10] = (now_ns() - start) / 1000;
  }
  qsort(t, FRAMES, sizeof t[0], compare);
  return t[FRAMES / 2];
}

static void test_window(EGLDisplay d) {
  static const EGLint want[] = {EGL_RED_SIZE, 8, EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
  EGLConfig c;
  EGLint n = 0;
  if (!eglChooseConfig(d, want, &c, 1, &n) || n < 1) return fail("window: no window config");
  struct vectra_egl_window native = {SIZE * 2, SIZE * 2, "gl-test"};
  EGLSurface s = eglCreateWindowSurface(d, c, &native, NULL);
  if (s == EGL_NO_SURFACE) {
    printf("gl-test: skipped: gl window (no window: EGL error 0x%04x)\n", eglGetError());
    return;
  }
  static const EGLint attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLContext ctx = eglCreateContext(d, c, EGL_NO_CONTEXT, attribs);
  if (!eglMakeCurrent(d, s, s, ctx)) return fail("window: eglMakeCurrent");
  EGLint w = 0, h = 0;
  eglQuerySurface(d, s, EGL_WIDTH, &w);
  eglQuerySurface(d, s, EGL_HEIGHT, &h);
  int ok = w > 0 && h > 0;
  // Interval 1: each swap waits for the compositor; then 0: none does.
  for (int interval = 1; interval >= 0; interval--) {
    eglSwapInterval(d, interval);
    uint64_t start = now_ns();
    for (int i = 0; i < 60; i++) {
      glClearColor((float)(i % 2), 0, (float)((i + 1) % 2), 1);
      glClear(GL_COLOR_BUFFER_BIT);
      if (!eglSwapBuffers(d, s)) {
        printf("gl-test: window: swap %d at interval %d: EGL error 0x%04x\n", i, interval, eglGetError());
        ok = 0;
        break;
      }
    }
    printf("gl-test: window: 60 swaps at interval %d in %llu us\n", interval, (unsigned long long)((now_ns() - start) / 1000));
  }
  // What is drawn reads back, the window's first row its top.
  glClearColor(0, 1, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  uint8_t px[4];
  glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
  if (!near(px, green, 0)) ok = 0;
  eglSwapBuffers(d, s);
  if (ok && check_gl("window")) printf("gl-test: ok: gl window\n");
  else fail("window");
  eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroySurface(d, s);
  eglDestroyContext(d, ctx);
}

int main(void) {
  EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  EGLint major = 0, minor = 0;
  if (!eglInitialize(d, &major, &minor)) {
    printf("gl-test: FAILED: eglInitialize: EGL error 0x%04x\n", eglGetError());
    return 1;
  }
  printf("gl-test: EGL %d.%d, %s\n", major, minor, eglQueryString(d, EGL_VENDOR));
  static const EGLint want[] = {EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24,
                                EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE};
  EGLConfig config;
  EGLint n = 0;
  if (!eglChooseConfig(d, want, &config, 1, &n) || n < 1) {
    printf("gl-test: FAILED: no RGBA8888 config with depth 24 for a pbuffer\n");
    return 1;
  }
  static const EGLint size[] = {EGL_WIDTH, SIZE, EGL_HEIGHT, SIZE, EGL_NONE};
  EGLSurface pbuffer = eglCreatePbufferSurface(d, config, size);
  static const EGLint three[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  if (eglCreateContext(d, config, EGL_NO_CONTEXT, three) != EGL_NO_CONTEXT) fail("a GL ES 3 context was made");
  static const EGLint two[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLContext ctx = eglCreateContext(d, config, EGL_NO_CONTEXT, two);
  if (pbuffer == EGL_NO_SURFACE || ctx == EGL_NO_CONTEXT || !eglMakeCurrent(d, pbuffer, pbuffer, ctx)) {
    printf("gl-test: FAILED: a pbuffer and a context: EGL error 0x%04x\n", eglGetError());
    return 1;
  }
  printf("gl-test: %s, %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
  if (!eglGetProcAddress("glDrawArrays") || !eglGetProcAddress("eglSwapBuffers")) fail("eglGetProcAddress");

  flat = PROGRAM(flat_vert, flat_frag);
  textured = PROGRAM(textured_vert, textured_frag);
  shaded = PROGRAM(shaded_vert, shaded_frag);
  static const float full[] = {-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1};
  glGenBuffers(1, &full_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, full_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof full, full, GL_STATIC_DRAW);
  // A strip of x and y -1 to 1 with texture coordinates 0 to 1.
  static const float quad[] = {-1, -1, 0, 1, 0, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1};
  glGenBuffers(1, &quad_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, quad_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
  check_gl("setup");

  test_clear();
  test_triangle();
  test_texture();
  test_depth();
  test_blend();
  test_render_to_texture();
  test_many_draws();
  test_client_arrays();

  uint64_t empty = frame_us(0), drawn = frame_us(1);
  printf("gl-test: budget name=gl.frame_us.empty value=%llu unit=us limit=200\n", (unsigned long long)empty);
  printf("gl-test: budget name=gl.frame_us.draw value=%llu unit=us limit=250\n", (unsigned long long)drawn);

  eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroySurface(d, pbuffer);
  eglDestroyContext(d, ctx);
  test_window(d);
  eglTerminate(d);
  if (failures) {
    printf("gl-test: %d checks failed\n", failures);
    return 1;
  }
  printf("gl-test: all checks passed\n");
  return 0;
}
