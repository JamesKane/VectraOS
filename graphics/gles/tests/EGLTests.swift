// SPDX-License-Identifier: BSD-3-Clause

// EGL through its C entry points, on a platform of the test's: a test device and a window that records what it is
// given and presented. Configs and their choice, pbuffers, contexts (2 made, 3 refused), MakeCurrent, swaps of a
// window at intervals 1 and 0, and GetProcAddress's names (c/procs.c is C, so only the Swift side is here).

import GPUCore
import Testing

@testable import GLES

final class TestWindow: GLWindow {
  var width: Int32 = 80
  var height: Int32 = 60
  var images: [(vmo: UInt32, stride: Int32, acquire: UInt32?)] = []
  var presented: [(image: UInt32, drawnAt: UInt64?, wait: Bool)] = []
  /// What the compositor does with a present: takes it, or (interval 0, no credit) not.
  var takes = true
  var busy: Set<UInt32> = []
  var closed = false
  func pump() {}
  func wait(nanoseconds: UInt64) {}
  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, acquire: UInt32?) -> UInt32? {
    images.append((vmo, stride, acquire))
    return UInt32(images.count)
  }
  func removeImage(_ image: UInt32) {}
  func isFree(_ image: UInt32) -> Bool { !busy.contains(image) }
  func present(_ image: UInt32, drawnAt: UInt64?, wait: Bool) -> WindowPresent {
    presented.append((image, drawnAt, wait))
    if !takes && !wait { return .notTaken }
    // The compositor holds what it shows until the next is shown.
    busy = [image]
    return .shown
  }
  func close() { closed = true }
}

final class TestPlatform: GLPlatform {
  let device = TestDevice()
  var windows: [TestWindow] = []
  func openDevice() throws(GPUError) -> any GPUDevice { device }
  func openWindow(title: String, width: Int32, height: Int32) -> (any GLWindow)? {
    let w = TestWindow()
    w.width = width
    w.height = height
    windows.append(w)
    return w
  }
}

extension GLTests {
  /// A fresh display, on a platform of the test's.
  func display() -> EGLHandle? {
    unsafe glPlatform = TestPlatform()
    EGLState.shared.display.initialized = false
    EGLState.shared.display.device = nil
    EGLState.shared.display.frame = nil
    EGLState.shared.current = nil
    unsafe currentContext = nil
    let d = gles_eglGetDisplay(nil)
    var major: EGLint = 0, minor: EGLint = 0
    #expect(gles_eglInitialize(d, &major, &minor) == 1)
    #expect(major == 1 && minor == 5)
    return d
  }

  func choose(_ d: EGLHandle?, _ attributes: [EGLint]) -> [EGLHandle?] {
    var configs = [EGLHandle?](repeating: nil, count: 64)
    var n: EGLint = 0
    #expect(gles_eglChooseConfig(d, attributes + [EGL_NONE], &configs, 64, &n) == 1)
    return Array(configs.prefix(Int(n)))
  }

  func attribute(_ d: EGLHandle?, _ c: EGLHandle?, _ a: EGLint) -> EGLint {
    var v: EGLint = -99
    #expect(gles_eglGetConfigAttrib(d, c, a, &v) == 1)
    return v
  }

  @Test func configsAreChosenAsTheSpecSorts() {
    let d = display()
    var n: EGLint = 0
    #expect(gles_eglGetConfigs(d, nil, 0, &n) == 1)
    // Three colour formats; depth 0, 16 and 24, stencil 0 and 8 where the device has the target.
    #expect(n == 3 * 5)
    let rgba = choose(d, [EGL_RED_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT])
    #expect(!rgba.isEmpty)
    #expect(attribute(d, rgba[0], EGL_ALPHA_SIZE) == 8 && attribute(d, rgba[0], EGL_DEPTH_SIZE) == 24)
    // The smallest depth and stencil that meet the request come first.
    #expect(attribute(d, rgba[0], EGL_STENCIL_SIZE) == 0)
    // EGL's default renderable type is OpenGL ES 1's, which no config is.
    #expect(choose(d, [EGL_RED_SIZE, 5]).isEmpty)
    let small = choose(d, [EGL_RED_SIZE, 5, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT])
    // More colour bits of what was asked for first, then the smaller buffer.
    #expect(attribute(d, small[0], EGL_RED_SIZE) == 8)
    let none = choose(d, [EGL_DEPTH_SIZE, 32, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT])
    #expect(none.isEmpty)
    var configs = [EGLHandle?](repeating: nil, count: 1)
    #expect(gles_eglChooseConfig(d, [0x7777, 1, EGL_NONE], &configs, 1, &n) == 0)
    #expect(gles_eglGetError() == EGL_BAD_ATTRIBUTE)
    #expect(attribute(d, rgba[0], EGL_SURFACE_TYPE) & EGL_WINDOW_BIT != 0)
    #expect(String(cString: gles_eglQueryString(d, EGL_CLIENT_APIS)!) == "OpenGL_ES")
  }

  @Test func contextsAreGLES2() {
    let d = display()
    let c = choose(d, [EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT])[0]
    #expect(gles_eglCreateContext(d, c, nil, [EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE]) == nil)
    #expect(gles_eglGetError() == EGL_BAD_MATCH)
    let context = gles_eglCreateContext(d, c, nil, [EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE])
    #expect(context != nil)
    let pbuffer = gles_eglCreatePbufferSurface(d, c, [EGL_WIDTH, 32, EGL_HEIGHT, 16, EGL_NONE])
    #expect(pbuffer != nil)
    #expect(gles_eglMakeCurrent(d, pbuffer, pbuffer, context) == 1)
    #expect(gles_eglGetCurrentContext() == context)
    #expect(gles_eglGetCurrentSurface(EGL_DRAW) == pbuffer)
    var w: EGLint = 0
    #expect(gles_eglQuerySurface(d, pbuffer, EGL_WIDTH, &w) == 1 && w == 32)
    var version: EGLint = 0
    #expect(gles_eglQueryContext(d, context, EGL_CONTEXT_CLIENT_VERSION, &version) == 1 && version == 2)
    // GL works on it.
    var v = [GLint](repeating: 0, count: 4)
    gles_glGetIntegerv(GL_VIEWPORT, &v)
    #expect(v == [0, 0, 32, 16])
    gles_glClearColor(0, 0, 1, 1)
    gles_glClear(GL_COLOR_BUFFER_BIT)
    var pixel = [UInt8](repeating: 0, count: 4)
    gles_glReadPixels(31, 15, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &pixel)
    #expect(pixel == [0, 0, 255, 255])
    #expect(gles_eglSwapBuffers(d, pbuffer) == 1)
    #expect(gles_eglMakeCurrent(d, nil, nil, nil) == 1)
    #expect(gles_eglGetCurrentContext() == nil)
    #expect(gles_eglDestroySurface(d, pbuffer) == 1)
    #expect(gles_eglDestroyContext(d, context) == 1)
    #expect(gles_eglDestroyContext(d, context) == 0)
    #expect(gles_eglGetError() == EGL_BAD_CONTEXT)
  }

  @Test func aWindowSwapsWithoutWaitingAtIntervalZero() {
    let d = display()
    let c = choose(d, [EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_DEPTH_SIZE, 16, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT])[0]
    let context = gles_eglCreateContext(d, c, nil, [EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE])
    let title = "gl window"
    let surface = title.withCString { t -> EGLHandle? in
      var native = (UInt32(80), UInt32(60), t)
      return withUnsafeMutableBytes(of: &native) { gles_eglCreateWindowSurface(d, c, $0.baseAddress, nil) }
    }
    #expect(surface != nil)
    let platform = unsafe glPlatform as! TestPlatform
    let w = platform.windows[0]
    #expect(w.images.count == 3)
    #expect(gles_eglMakeCurrent(d, surface, surface, context) == 1)
    for _ in 0..<3 {
      gles_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
      #expect(gles_eglSwapBuffers(d, surface) == 1)
    }
    #expect(w.presented.count == 3)
    #expect(w.presented.allSatisfy { $0.wait })
    // Each frame drawn into another image than the one shown.
    #expect(Set(w.presented.map(\.image)).count >= 2)
    #expect(gles_eglSwapInterval(d, 0) == 1)
    w.takes = false
    gles_glClear(GL_COLOR_BUFFER_BIT)
    #expect(gles_eglSwapBuffers(d, surface) == 1)
    #expect(w.presented.last!.wait == false)
    let s = EGLState.shared.surfaces[UInt(bitPattern: surface)]!
    #expect(s.framesDropped == 1)
    // The staged device's copy for the window is in the swap's list.
    let device = platform.device
    #expect(device.commands.contains { if case .copyImageToBuffer = $0 { true } else { false } })
    #expect(gles_eglMakeCurrent(d, nil, nil, nil) == 1)
    #expect(gles_eglDestroySurface(d, surface) == 1)
    #expect(w.closed)
  }
}
