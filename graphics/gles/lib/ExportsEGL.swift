// SPDX-License-Identifier: BSD-3-Clause

// EGL's C entry points (egl(3)): each `gles_egl*` the C names in libEGL.so call (c/libEGL.c). eglGetProcAddress is
// C's (c/procs.c).

import GPUCore

public typealias EGLHandle = UnsafeMutableRawPointer

var egl: EGLState { EGLState.shared }

/// `attribs`' (name, value) pairs, up to EGL_NONE.
func pairs(_ attribs: UnsafePointer<EGLint>?) -> [(EGLint, EGLint)] {
  guard let a = unsafe attribs else { return [] }
  var out: [(EGLint, EGLint)] = []
  var i = 0
  while unsafe a[i] != EGL_NONE {
    out.append(unsafe (a[i], a[i + 1]))
    i += 2
  }
  return out
}

func pairs(_ attribs: UnsafePointer<EGLAttrib>?) -> [(EGLint, EGLint)] {
  guard let a = unsafe attribs else { return [] }
  var out: [(EGLint, EGLint)] = []
  var i = 0
  while unsafe a[i] != EGLAttrib(EGL_NONE) {
    out.append(unsafe (EGLint(truncatingIfNeeded: a[i]), EGLint(truncatingIfNeeded: a[i + 1])))
    i += 2
  }
  return out
}

/// Succeeds: the error is EGL_SUCCESS.
@inline(__always) func ok(_ v: Bool = true) -> EGLBoolean {
  if v { egl.error = EGL_SUCCESS }
  return v.egl
}

nonisolated(unsafe) var eglStrings: [EGLint: UnsafeMutablePointer<CChar>] = unsafe [:]

func eglString(_ key: EGLint, _ text: String) -> UnsafePointer<CChar> {
  if let p = unsafe eglStrings[key] { return unsafe UnsafePointer(p) }
  let bytes = Array(text.utf8)
  let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
  for (i, b) in bytes.enumerated() { unsafe p[i] = CChar(bitPattern: b) }
  unsafe p[bytes.count] = 0
  unsafe eglStrings[key] = p
  return unsafe UnsafePointer(p)
}

// MARK: Displays

@c(gles_eglGetDisplay) public func gles_eglGetDisplay(_ native: UnsafeMutableRawPointer?) -> EGLHandle? {
  // EGL_DEFAULT_DISPLAY, or anything else: the one display.
  unsafe UnsafeMutableRawPointer(bitPattern: EGLState.displayHandle)
}
@c(gles_eglGetPlatformDisplay) public func gles_eglGetPlatformDisplay(_ platform: EGLenum, _ native: UnsafeMutableRawPointer?,
                                                                      _ attribs: UnsafePointer<EGLAttrib>?) -> EGLHandle? {
  unsafe UnsafeMutableRawPointer(bitPattern: EGLState.displayHandle)
}
@c(gles_eglInitialize) public func gles_eglInitialize(_ dpy: EGLHandle?, _ major: UnsafeMutablePointer<EGLint>?,
                                                      _ minor: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard let d = unsafe egl.display(dpy, initialized: false) else { return 0 }
  let e = d.initialize()
  guard e == EGL_SUCCESS else {
    egl.fail(e)
    return 0
  }
  unsafe major?.pointee = 1
  unsafe minor?.pointee = 5
  return ok()
}
@c(gles_eglTerminate) public func gles_eglTerminate(_ dpy: EGLHandle?) -> EGLBoolean {
  guard let d = unsafe egl.display(dpy, initialized: false) else { return 0 }
  d.initialized = false
  for (h, s) in egl.surfaces where s.boundContext == nil || s.boundContext !== egl.current {
    s.release()
    egl.surfaces[h] = nil
  }
  for (h, c) in egl.contexts where c !== egl.current { egl.contexts[h] = nil }
  return ok()
}
@c(gles_eglQueryString) public func gles_eglQueryString(_ dpy: EGLHandle?, _ name: EGLint) -> UnsafePointer<CChar>? {
  if unsafe dpy == nil && name == EGL_EXTENSIONS {
    egl.error = EGL_SUCCESS
    return unsafe eglString(-1, "EGL_EXT_client_extensions EGL_EXT_platform_base")
  }
  guard unsafe egl.display(dpy) != nil else { return nil }
  egl.error = EGL_SUCCESS
  switch name {
  case EGL_VENDOR: return unsafe eglString(name, "VectraOS")
  case EGL_VERSION: return unsafe eglString(name, "1.5 VectraOS")
  case EGL_CLIENT_APIS: return unsafe eglString(name, "OpenGL_ES")
  case EGL_EXTENSIONS: return unsafe eglString(name, "EGL_KHR_create_context EGL_KHR_surfaceless_context EGL_KHR_fence_sync")
  default:
    egl.fail(EGL_BAD_PARAMETER)
    return nil
  }
}

// MARK: Configs

func writeConfigs(_ list: [EGLConfigInfo], _ out: UnsafeMutablePointer<EGLHandle?>?, _ size: EGLint,
                  _ count: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard let count = unsafe count else {
    egl.fail(EGL_BAD_PARAMETER)
    return 0
  }
  guard let out = unsafe out else {
    unsafe count.pointee = EGLint(list.count)
    return ok()
  }
  let n = min(Int(max(size, 0)), list.count)
  for i in 0..<n { unsafe out[i] = UnsafeMutableRawPointer(bitPattern: EGLState.configBase + UInt(list[i].id)) }
  unsafe count.pointee = EGLint(n)
  return ok()
}

@c(gles_eglGetConfigs) public func gles_eglGetConfigs(_ dpy: EGLHandle?, _ configs: UnsafeMutablePointer<EGLHandle?>?, _ size: EGLint,
                                                      _ count: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard let d = unsafe egl.display(dpy) else { return 0 }
  return unsafe writeConfigs(d.configs, configs, size, count)
}
@c(gles_eglChooseConfig) public func gles_eglChooseConfig(_ dpy: EGLHandle?, _ attribs: UnsafePointer<EGLint>?,
                                                          _ configs: UnsafeMutablePointer<EGLHandle?>?, _ size: EGLint,
                                                          _ count: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard let d = unsafe egl.display(dpy) else { return 0 }
  guard let list = d.choose(unsafe pairs(attribs)) else {
    egl.fail(EGL_BAD_ATTRIBUTE)
    return 0
  }
  return unsafe writeConfigs(list, configs, size, count)
}
@c(gles_eglGetConfigAttrib) public func gles_eglGetConfigAttrib(_ dpy: EGLHandle?, _ config: EGLHandle?, _ attribute: EGLint,
                                                                _ value: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard let d = unsafe egl.display(dpy), let c = unsafe egl.config(d, config) else { return 0 }
  guard let v = d.attribute(c, attribute) else {
    egl.fail(EGL_BAD_ATTRIBUTE)
    return 0
  }
  unsafe value?.pointee = v
  return ok()
}

// MARK: Surfaces

@c(gles_eglCreateWindowSurface) public func gles_eglCreateWindowSurface(_ dpy: EGLHandle?, _ config: EGLHandle?,
                                                                        _ window: UnsafeMutableRawPointer?,
                                                                        _ attribs: UnsafePointer<EGLint>?) -> EGLHandle? {
  guard let d = unsafe egl.display(dpy), let c = unsafe egl.config(d, config) else { return nil }
  let s = unsafe egl.createWindow(d, c, window, pairs(attribs))
  if unsafe s != nil { egl.error = EGL_SUCCESS }
  return unsafe s
}
@c(gles_eglCreatePlatformWindowSurface) public func gles_eglCreatePlatformWindowSurface(_ dpy: EGLHandle?, _ config: EGLHandle?,
                                                                                        _ window: UnsafeMutableRawPointer?,
                                                                                        _ attribs: UnsafePointer<EGLAttrib>?) -> EGLHandle? {
  guard let d = unsafe egl.display(dpy), let c = unsafe egl.config(d, config) else { return nil }
  let s = unsafe egl.createWindow(d, c, window, pairs(attribs))
  if unsafe s != nil { egl.error = EGL_SUCCESS }
  return unsafe s
}
@c(gles_eglCreatePbufferSurface) public func gles_eglCreatePbufferSurface(_ dpy: EGLHandle?, _ config: EGLHandle?,
                                                                          _ attribs: UnsafePointer<EGLint>?) -> EGLHandle? {
  guard let d = unsafe egl.display(dpy), let c = unsafe egl.config(d, config) else { return nil }
  let s = unsafe egl.createPbuffer(d, c, pairs(attribs))
  if unsafe s != nil { egl.error = EGL_SUCCESS }
  return unsafe s
}
@c(gles_eglCreatePixmapSurface) public func gles_eglCreatePixmapSurface(_ dpy: EGLHandle?, _ config: EGLHandle?,
                                                                        _ pixmap: UnsafeMutableRawPointer?,
                                                                        _ attribs: UnsafePointer<EGLint>?) -> EGLHandle? {
  // No config has EGL_PIXMAP_BIT.
  egl.fail(EGL_BAD_MATCH)
  return nil
}
@c(gles_eglCreatePlatformPixmapSurface) public func gles_eglCreatePlatformPixmapSurface(_ dpy: EGLHandle?, _ config: EGLHandle?,
                                                                                        _ pixmap: UnsafeMutableRawPointer?,
                                                                                        _ attribs: UnsafePointer<EGLAttrib>?) -> EGLHandle? {
  egl.fail(EGL_BAD_MATCH)
  return nil
}
@c(gles_eglCreatePbufferFromClientBuffer) public func gles_eglCreatePbufferFromClientBuffer(
  _ dpy: EGLHandle?, _ type: EGLenum, _ buffer: UnsafeMutableRawPointer?, _ config: EGLHandle?, _ attribs: UnsafePointer<EGLint>?
) -> EGLHandle? {
  egl.fail(EGL_BAD_PARAMETER)
  return nil
}
@c(gles_eglDestroySurface) public func gles_eglDestroySurface(_ dpy: EGLHandle?, _ surface: EGLHandle?) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil else { return 0 }
  return ok(unsafe egl.destroySurface(surface))
}
@c(gles_eglQuerySurface) public func gles_eglQuerySurface(_ dpy: EGLHandle?, _ surface: EGLHandle?, _ attribute: EGLint,
                                                          _ value: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil, let s = unsafe egl.surface(surface) else { return 0 }
  let v: EGLint
  switch attribute {
  case EGL_WIDTH: v = s.width
  case EGL_HEIGHT: v = s.height
  case EGL_CONFIG_ID: v = s.config.id
  case EGL_RENDER_BUFFER: v = EGL_BACK_BUFFER
  case EGL_SWAP_BEHAVIOR: v = EGL_BUFFER_DESTROYED
  case EGL_LARGEST_PBUFFER, EGL_MIPMAP_TEXTURE, EGL_MIPMAP_LEVEL: v = 0
  case EGL_TEXTURE_FORMAT, EGL_TEXTURE_TARGET: v = EGL_NO_TEXTURE
  case EGL_HORIZONTAL_RESOLUTION, EGL_VERTICAL_RESOLUTION, EGL_PIXEL_ASPECT_RATIO: v = EGL_UNKNOWN
  case EGL_MULTISAMPLE_RESOLVE: v = EGL_MULTISAMPLE_RESOLVE_DEFAULT
  case EGL_GL_COLORSPACE: v = EGL_GL_COLORSPACE_LINEAR
  default:
    egl.fail(EGL_BAD_ATTRIBUTE)
    return 0
  }
  unsafe value?.pointee = v
  return ok()
}
@c(gles_eglSurfaceAttrib) public func gles_eglSurfaceAttrib(_ dpy: EGLHandle?, _ surface: EGLHandle?, _ attribute: EGLint,
                                                            _ value: EGLint) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil, unsafe egl.surface(surface) != nil else { return 0 }
  switch attribute {
  case EGL_SWAP_BEHAVIOR:
    guard value == EGL_BUFFER_DESTROYED else {
      egl.fail(EGL_BAD_MATCH)
      return 0
    }
  case EGL_MIPMAP_LEVEL, EGL_MULTISAMPLE_RESOLVE: break
  default:
    egl.fail(EGL_BAD_ATTRIBUTE)
    return 0
  }
  return ok()
}
@c(gles_eglBindTexImage) public func gles_eglBindTexImage(_ dpy: EGLHandle?, _ surface: EGLHandle?, _ buffer: EGLint) -> EGLBoolean {
  egl.fail(EGL_BAD_MATCH)
  return 0
}
@c(gles_eglReleaseTexImage) public func gles_eglReleaseTexImage(_ dpy: EGLHandle?, _ surface: EGLHandle?, _ buffer: EGLint) -> EGLBoolean {
  egl.fail(EGL_BAD_MATCH)
  return 0
}
@c(gles_eglCopyBuffers) public func gles_eglCopyBuffers(_ dpy: EGLHandle?, _ surface: EGLHandle?, _ pixmap: UnsafeMutableRawPointer?) -> EGLBoolean {
  egl.fail(EGL_BAD_NATIVE_PIXMAP)
  return 0
}
@c(gles_eglSwapBuffers) public func gles_eglSwapBuffers(_ dpy: EGLHandle?, _ surface: EGLHandle?) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil, let s = unsafe egl.surface(surface) else { return 0 }
  guard let c = egl.current, c.draw === s else {
    egl.fail(EGL_BAD_SURFACE)
    return 0
  }
  do throws(GPUError) {
    guard try s.swap(c.gl.frame) else {
      egl.fail(EGL_BAD_NATIVE_WINDOW)
      return 0
    }
  } catch {
    say("a swap: \(error)")
    egl.fail(EGL_BAD_ALLOC)
    return 0
  }
  return ok()
}
@c(gles_eglSwapInterval) public func gles_eglSwapInterval(_ dpy: EGLHandle?, _ interval: EGLint) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil else { return 0 }
  guard let c = egl.current, let s = c.draw else {
    egl.fail(EGL_BAD_SURFACE)
    return 0
  }
  s.swapInterval = min(max(interval, 0), 1)
  return ok()
}

// MARK: Contexts

@c(gles_eglBindAPI) public func gles_eglBindAPI(_ api: EGLenum) -> EGLBoolean {
  guard api == EGLenum(EGL_OPENGL_ES_API) else {
    egl.fail(EGL_BAD_PARAMETER)
    return 0
  }
  egl.api = api
  return ok()
}
@c(gles_eglQueryAPI) public func gles_eglQueryAPI() -> EGLenum { egl.api }
@c(gles_eglCreateContext) public func gles_eglCreateContext(_ dpy: EGLHandle?, _ config: EGLHandle?, _ share: EGLHandle?,
                                                            _ attribs: UnsafePointer<EGLint>?) -> EGLHandle? {
  guard let d = unsafe egl.display(dpy) else { return nil }
  var c: EGLConfigInfo? = nil
  if unsafe config != nil {
    guard let found = unsafe egl.config(d, config) else { return nil }
    c = found
  }
  var shared: EGLContextObject? = nil
  if unsafe share != nil {
    guard let s = unsafe egl.context(share) else { return nil }
    shared = s
  }
  let h = unsafe egl.createContext(d, c, share: shared, pairs(attribs))
  if unsafe h != nil { egl.error = EGL_SUCCESS }
  return unsafe h
}
@c(gles_eglDestroyContext) public func gles_eglDestroyContext(_ dpy: EGLHandle?, _ context: EGLHandle?) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil else { return 0 }
  return ok(unsafe egl.destroyContext(context))
}
@c(gles_eglMakeCurrent) public func gles_eglMakeCurrent(_ dpy: EGLHandle?, _ draw: EGLHandle?, _ read: EGLHandle?, _ context: EGLHandle?) -> EGLBoolean {
  if unsafe context == nil {
    guard unsafe draw == nil && read == nil else {
      egl.fail(EGL_BAD_MATCH)
      return 0
    }
    egl.makeCurrent(nil, draw: nil)
    return ok()
  }
  guard unsafe egl.display(dpy) != nil, let c = unsafe egl.context(context) else { return 0 }
  guard unsafe draw == read else {
    egl.fail(EGL_BAD_MATCH)
    return 0
  }
  var s: EGLSurfaceObject? = nil
  if unsafe draw != nil {
    guard let found = unsafe egl.surface(draw) else { return 0 }
    s = found
  }
  egl.makeCurrent(c, draw: s)
  return ok()
}
@c(gles_eglGetCurrentContext) public func gles_eglGetCurrentContext() -> EGLHandle? { unsafe egl.handle(of: egl.current) }
@c(gles_eglGetCurrentSurface) public func gles_eglGetCurrentSurface(_ which: EGLint) -> EGLHandle? {
  guard which == EGL_DRAW || which == EGL_READ else {
    egl.fail(EGL_BAD_PARAMETER)
    return nil
  }
  return unsafe egl.handle(of: egl.current?.draw)
}
@c(gles_eglGetCurrentDisplay) public func gles_eglGetCurrentDisplay() -> EGLHandle? {
  egl.current == nil ? nil : unsafe UnsafeMutableRawPointer(bitPattern: EGLState.displayHandle)
}
@c(gles_eglQueryContext) public func gles_eglQueryContext(_ dpy: EGLHandle?, _ context: EGLHandle?, _ attribute: EGLint,
                                                          _ value: UnsafeMutablePointer<EGLint>?) -> EGLBoolean {
  guard unsafe egl.display(dpy) != nil, let c = unsafe egl.context(context) else { return 0 }
  let v: EGLint
  switch attribute {
  case EGL_CONFIG_ID: v = c.config?.id ?? 0
  case EGL_CONTEXT_CLIENT_TYPE: v = EGL_OPENGL_ES_API
  case EGL_CONTEXT_CLIENT_VERSION: v = 2
  case EGL_RENDER_BUFFER: v = c.draw == nil ? EGL_NONE : EGL_BACK_BUFFER
  default:
    egl.fail(EGL_BAD_ATTRIBUTE)
    return 0
  }
  unsafe value?.pointee = v
  return ok()
}
@c(gles_eglReleaseThread) public func gles_eglReleaseThread() -> EGLBoolean {
  egl.makeCurrent(nil, draw: nil)
  return ok()
}
@c(gles_eglWaitClient) public func gles_eglWaitClient() -> EGLBoolean {
  egl.current?.gl.finish()
  return ok()
}
@c(gles_eglWaitGL) public func gles_eglWaitGL() -> EGLBoolean {
  egl.current?.gl.finish()
  return ok()
}
@c(gles_eglWaitNative) public func gles_eglWaitNative(_ engine: EGLint) -> EGLBoolean { ok() }
@c(gles_eglGetError) public func gles_eglGetError() -> EGLint {
  defer { egl.error = EGL_SUCCESS }
  return egl.error
}

// MARK: Syncs (EGL 1.5): a fence is the timeline value of what was submitted before it.

@c(gles_eglCreateSync) public func gles_eglCreateSync(_ dpy: EGLHandle?, _ type: EGLenum, _ attribs: UnsafePointer<EGLAttrib>?) -> EGLHandle? {
  guard unsafe egl.display(dpy) != nil else { return nil }
  guard type == EGLenum(EGL_SYNC_FENCE) else {
    egl.fail(EGL_BAD_ATTRIBUTE)
    return nil
  }
  guard let c = egl.current else {
    egl.fail(EGL_BAD_MATCH)
    return nil
  }
  let value: UInt64
  do throws(GPUError) { value = try c.gl.frame.submit() } catch {
    egl.fail(EGL_BAD_ALLOC)
    return nil
  }
  let h = egl.handle()
  egl.syncs[h] = value
  egl.error = EGL_SUCCESS
  return unsafe UnsafeMutableRawPointer(bitPattern: h)
}
@c(gles_eglDestroySync) public func gles_eglDestroySync(_ dpy: EGLHandle?, _ sync: EGLHandle?) -> EGLBoolean {
  guard egl.syncs.removeValue(forKey: UInt(bitPattern: unsafe sync)) != nil else {
    egl.fail(EGL_BAD_PARAMETER)
    return 0
  }
  return ok()
}
@c(gles_eglClientWaitSync) public func gles_eglClientWaitSync(_ dpy: EGLHandle?, _ sync: EGLHandle?, _ flags: EGLint, _ timeout: UInt64) -> EGLint {
  guard let value = egl.syncs[UInt(bitPattern: unsafe sync)], let device = egl.display.device else {
    egl.fail(EGL_BAD_PARAMETER)
    return 0
  }
  if device.completed >= value { return EGL_CONDITION_SATISFIED }
  if timeout == 0 { return EGL_TIMEOUT_EXPIRED }
  do throws(GPUError) { try device.wait(value) } catch { return 0 }
  return EGL_CONDITION_SATISFIED
}
@c(gles_eglWaitSync) public func gles_eglWaitSync(_ dpy: EGLHandle?, _ sync: EGLHandle?, _ flags: EGLint) -> EGLBoolean {
  // The GPU's work is in order on its one queue: a wait in it has nothing to wait for.
  ok(egl.syncs[UInt(bitPattern: unsafe sync)] != nil)
}
@c(gles_eglGetSyncAttrib) public func gles_eglGetSyncAttrib(_ dpy: EGLHandle?, _ sync: EGLHandle?, _ attribute: EGLint,
                                                            _ value: UnsafeMutablePointer<EGLAttrib>?) -> EGLBoolean {
  guard let v = egl.syncs[UInt(bitPattern: unsafe sync)], let device = egl.display.device else {
    egl.fail(EGL_BAD_PARAMETER)
    return 0
  }
  switch attribute {
  case EGL_SYNC_TYPE: unsafe value?.pointee = EGLAttrib(EGL_SYNC_FENCE)
  case EGL_SYNC_STATUS: unsafe value?.pointee = EGLAttrib(device.completed >= v ? EGL_SIGNALED : EGL_UNSIGNALED)
  case EGL_SYNC_CONDITION: unsafe value?.pointee = EGLAttrib(EGL_SYNC_PRIOR_COMMANDS_COMPLETE)
  default:
    egl.fail(EGL_BAD_ATTRIBUTE)
    return 0
  }
  return ok()
}

// MARK: Images: none.

@c(gles_eglCreateImage) public func gles_eglCreateImage(_ dpy: EGLHandle?, _ context: EGLHandle?, _ target: EGLenum,
                                                        _ buffer: UnsafeMutableRawPointer?, _ attribs: UnsafePointer<EGLAttrib>?) -> EGLHandle? {
  egl.fail(EGL_BAD_PARAMETER)
  return nil
}
@c(gles_eglDestroyImage) public func gles_eglDestroyImage(_ dpy: EGLHandle?, _ image: EGLHandle?) -> EGLBoolean {
  egl.fail(EGL_BAD_PARAMETER)
  return 0
}
