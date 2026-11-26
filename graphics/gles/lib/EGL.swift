// SPDX-License-Identifier: BSD-3-Clause

// EGL (egl(3)): the one display, its configs, pbuffer and window surfaces, contexts, and making them current, over a
// platform that opens the GPU and the windows (native/Platform.swift: the core's device, and Radharc's windows through
// the SDK; a test gives its own).
//
// A window surface is a window of Radharc's whose images are the core's present images (`makePresentImage`), as the
// Vulkan layer's swapchain is (vulkansurface(2)): a swap ends the frame's pass, adds what presenting needs (a staged
// device's copy), submits, and presents the image to the window naming the timeline value its drawing signals, so
// nothing waits on the CPU where the device gives its timeline as a handle. With a swap interval of 0 a swap never waits
// for the compositor: a frame it can't take now isn't shown, and the next is drawn into another image.

import GPUCore

/// What presenting an image of a window came to.
public enum WindowPresent: Equatable, Sendable {
  case shown
  /// The compositor takes no frame now (a swap interval of 0 doesn't wait for it).
  case notTaken
  case lost
}

/// A window EGL draws into: the platform's view of a window of Radharc's.
public protocol GLWindow: AnyObject {
  /// The window's content size in pixels.
  var width: Int32 { get }
  var height: Int32 { get }
  /// Takes what has arrived from the compositor, without blocking.
  func pump()
  /// Waits for something to arrive, for at most `nanoseconds`.
  func wait(nanoseconds: UInt64)
  /// Gives the window an image (the window takes `vmo`, and `acquire`, a counter of the device's timeline): its number.
  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, acquire: UInt32?) -> UInt32?
  func removeImage(_ image: UInt32)
  /// Whether the compositor reads the image no more.
  func isFree(_ image: UInt32) -> Bool
  /// Shows the image once the device's timeline reaches `drawnAt` (nil: drawn already); with `wait`, waits for the
  /// compositor to take a frame, else gives up at once if it takes none now.
  func present(_ image: UInt32, drawnAt: UInt64?, wait: Bool) -> WindowPresent
  func close()
}

/// What EGL runs on.
public protocol GLPlatform: AnyObject {
  /// The GPU's core device.
  func openDevice() throws(GPUError) -> any GPUDevice
  /// A window `width` by `height` titled `title`, once its first size is known; nil if there is no compositor.
  func openWindow(title: String, width: Int32, height: Int32) -> (any GLWindow)?
}

/// The platform EGL opens its display on.
public nonisolated(unsafe) var glPlatform: (any GLPlatform)? = defaultPlatform()

/// One of a display's configs.
struct EGLConfigInfo: Equatable {
  var id: EGLint
  var red: EGLint, green: EGLint, blue: EGLint, alpha: EGLint
  var depth: EGLint
  var stencil: EGLint
  var depthFormat: PixelFormat?

  var bufferSize: EGLint { red + green + blue + alpha }
}

public final class EGLDisplayObject {
  var initialized = false
  var device: (any GPUDevice)?
  var frame: Frame?
  var configs: [EGLConfigInfo] = []

  /// Opens the device, once, and lists the configs it can draw.
  func initialize() -> EGLint {
    if initialized { return EGL_SUCCESS }
    guard let platform = unsafe glPlatform else { return EGL_NOT_INITIALIZED }
    if device == nil {
      do throws(GPUError) {
        device = try platform.openDevice()
      } catch {
        say("no GPU: \(error)")
        return EGL_NOT_INITIALIZED
      }
      frame = Frame(device: device!)
    }
    configs = makeConfigs(device!)
    initialized = true
    return EGL_SUCCESS
  }

  func makeConfigs(_ d: any GPUDevice) -> [EGLConfigInfo] {
    func target(_ f: PixelFormat) -> Bool { d.limits.formats(f).depthTarget }
    var out: [EGLConfigInfo] = []
    let colors: [(EGLint, EGLint, EGLint, EGLint)] = [(8, 8, 8, 8), (8, 8, 8, 0), (5, 6, 5, 0)]
    for c in colors {
      for depth in [EGLint(0), 16, 24] {
        for stencil in [EGLint(0), 8] {
          var format: PixelFormat?
          switch (depth, stencil) {
          case (0, 0): format = nil
          case (16, 0): format = target(.depth16) ? .depth16 : nil
          case (24, 0): format = target(.depth32f) ? .depth32f : target(.depth24stencil8) ? .depth24stencil8 : nil
          case (24, 8): format = target(.depth24stencil8) ? .depth24stencil8 : target(.depth32fstencil8) ? .depth32fstencil8 : nil
          case (0, 8): format = target(.stencil8) ? .stencil8 : target(.depth24stencil8) ? .depth24stencil8 : nil
          default: continue
          }
          if (depth > 0 || stencil > 0) && format == nil { continue }
          out.append(EGLConfigInfo(id: EGLint(out.count + 1), red: c.0, green: c.1, blue: c.2, alpha: c.3, depth: depth,
                                   stencil: stencil, depthFormat: format))
        }
      }
    }
    return out
  }

  func config(_ id: EGLint) -> EGLConfigInfo? { configs.first { $0.id == id } }

  /// EGL_CONFIG_ATTRIB's value of `c`.
  func attribute(_ c: EGLConfigInfo, _ a: EGLint) -> EGLint? {
    let maxSize = EGLint(min(device?.limits.maxImageDimension ?? 4096, 4096))
    switch a {
    case EGL_BUFFER_SIZE: return c.bufferSize
    case EGL_RED_SIZE: return c.red
    case EGL_GREEN_SIZE: return c.green
    case EGL_BLUE_SIZE: return c.blue
    case EGL_ALPHA_SIZE: return c.alpha
    case EGL_LUMINANCE_SIZE, EGL_ALPHA_MASK_SIZE: return 0
    case EGL_DEPTH_SIZE: return c.depth
    case EGL_STENCIL_SIZE: return c.stencil
    case EGL_CONFIG_ID: return c.id
    case EGL_CONFIG_CAVEAT: return EGL_NONE
    case EGL_COLOR_BUFFER_TYPE: return EGL_RGB_BUFFER
    case EGL_LEVEL: return 0
    case EGL_MAX_PBUFFER_WIDTH, EGL_MAX_PBUFFER_HEIGHT: return maxSize
    case EGL_MAX_PBUFFER_PIXELS: return maxSize * maxSize
    case EGL_MAX_SWAP_INTERVAL: return 1
    case EGL_MIN_SWAP_INTERVAL: return 0
    case EGL_NATIVE_RENDERABLE: return EGL_FALSE
    case EGL_NATIVE_VISUAL_ID: return 0
    case EGL_NATIVE_VISUAL_TYPE: return EGL_NONE
    case EGL_SAMPLES, EGL_SAMPLE_BUFFERS: return 0
    case EGL_SURFACE_TYPE: return EGL_WINDOW_BIT | EGL_PBUFFER_BIT
    case EGL_RENDERABLE_TYPE, EGL_CONFORMANT: return EGL_OPENGL_ES2_BIT
    case EGL_TRANSPARENT_TYPE: return EGL_NONE
    case EGL_TRANSPARENT_RED_VALUE, EGL_TRANSPARENT_GREEN_VALUE, EGL_TRANSPARENT_BLUE_VALUE: return 0
    case EGL_BIND_TO_TEXTURE_RGB, EGL_BIND_TO_TEXTURE_RGBA: return EGL_FALSE
    default: return nil
    }
  }

  /// eglChooseConfig: the configs matching `attributes` (pairs), sorted as EGL 1.5's table 3.4 says. nil for an
  /// attribute EGL doesn't have (EGL_BAD_ATTRIBUTE).
  func choose(_ attributes: [(EGLint, EGLint)]) -> [EGLConfigInfo]? {
    var want: [EGLint: EGLint] = [EGL_SURFACE_TYPE: EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE: EGL_OPENGL_ES_BIT,
                                  EGL_COLOR_BUFFER_TYPE: EGL_RGB_BUFFER, EGL_CONFIG_CAVEAT: EGL_DONT_CARE]
    for (a, v) in attributes {
      guard a == EGL_MATCH_NATIVE_PIXMAP || attribute(configs.first ?? EGLConfigInfo(id: 0, red: 0, green: 0, blue: 0, alpha: 0,
                                                                                       depth: 0, stencil: 0), a) != nil
        || a == EGL_MAX_PBUFFER_WIDTH
      else { return nil }
      want[a] = v
    }
    // EGL_CONFIG_ID alone decides.
    if let id = want[EGL_CONFIG_ID], id != EGL_DONT_CARE { return configs.filter { $0.id == id } }
    let exact: Set<EGLint> = [EGL_COLOR_BUFFER_TYPE, EGL_CONFIG_CAVEAT, EGL_LEVEL, EGL_NATIVE_RENDERABLE, EGL_TRANSPARENT_TYPE,
                              EGL_MAX_SWAP_INTERVAL, EGL_MIN_SWAP_INTERVAL, EGL_NATIVE_VISUAL_TYPE, EGL_BIND_TO_TEXTURE_RGB,
                              EGL_BIND_TO_TEXTURE_RGBA]
    let masks: Set<EGLint> = [EGL_SURFACE_TYPE, EGL_RENDERABLE_TYPE, EGL_CONFORMANT]
    let ignored: Set<EGLint> = [EGL_MAX_PBUFFER_WIDTH, EGL_MAX_PBUFFER_HEIGHT, EGL_MAX_PBUFFER_PIXELS, EGL_NATIVE_VISUAL_ID,
                                EGL_MATCH_NATIVE_PIXMAP, EGL_TRANSPARENT_RED_VALUE, EGL_TRANSPARENT_GREEN_VALUE,
                                EGL_TRANSPARENT_BLUE_VALUE]
    var matched = configs.filter { c in
      for (a, v) in want where v != EGL_DONT_CARE && !ignored.contains(a) {
        guard let have = attribute(c, a) else { return false }
        if masks.contains(a) {
          if have & v != v { return false }
        } else if exact.contains(a) {
          if have != v { return false }
        } else if have < v {
          return false
        }
      }
      return true
    }
    func colorBits(_ c: EGLConfigInfo) -> EGLint {
      var n: EGLint = 0
      for (a, bits) in [(EGL_RED_SIZE, c.red), (EGL_GREEN_SIZE, c.green), (EGL_BLUE_SIZE, c.blue), (EGL_ALPHA_SIZE, c.alpha)] {
        if let v = want[a], v != 0, v != EGL_DONT_CARE { n += bits }
      }
      return n
    }
    matched.sort { a, b in
      if colorBits(a) != colorBits(b) { return colorBits(a) > colorBits(b) }
      if a.bufferSize != b.bufferSize { return a.bufferSize < b.bufferSize }
      if a.depth != b.depth { return a.depth < b.depth }
      if a.stencil != b.stencil { return a.stencil < b.stencil }
      return a.id < b.id
    }
    return matched
  }
}

/// A surface: a pbuffer's image, or a window's present images; its depth and stencil image; the target a context
/// bound to framebuffer 0 draws into.
public final class EGLSurfaceObject: DefaultFramebuffer {
  let display: EGLDisplayObject
  let config: EGLConfigInfo
  let width: Int32
  let height: Int32
  /// A pbuffer's colour image.
  var image: GPUImage?
  var depthImage: GPUImage?
  /// A window's.
  var window: (any GLWindow)?
  var frames: [PresentImage] = []
  var windowImages: [UInt32] = []
  var timeline = false
  var current = 0
  private(set) var serial: UInt64 = 1
  var swapInterval: EGLint = 1
  var destroyed = false
  /// The context it is current to, if any (it is destroyed once that is released).
  var boundContext: EGLContextObject?
  /// Swaps the compositor didn't take (interval 0).
  var framesDropped = 0
  var framesShown = 0

  init(display: EGLDisplayObject, config: EGLConfigInfo, width: Int32, height: Int32) {
    self.display = display
    self.config = config
    self.width = width
    self.height = height
  }

  var device: any GPUDevice { display.device! }

  var target: RenderTarget {
    var t = RenderTarget()
    if window != nil {
      let i = frames[current].image
      t.color = ImageView(i)
      t.colorFormat = i.format
      t.flipped = true
    } else if let i = image {
      t.color = ImageView(i)
      t.colorFormat = i.format
    }
    if let d = depthImage {
      t.depthStencil = ImageView(d)
      t.depthStencilFormat = d.format
      t.hasDepth = config.depth > 0
      t.hasStencil = config.stencil > 0
    }
    t.width = width
    t.height = height
    t.colorAlpha = config.alpha > 0
    t.redBits = config.red
    t.greenBits = config.green
    t.blueBits = config.blue
    t.alphaBits = config.alpha
    t.depthBits = config.depth
    t.stencilBits = config.stencil
    return t
  }

  func makeDepth() throws(GPUError) {
    guard let f = config.depthFormat else { return }
    depthImage = try device.makeImage(ImageDescriptor(format: f, width: width, height: height, usage: .depthStencilTarget))
  }

  /// A pbuffer of `width` by `height`.
  func makePbuffer() throws(GPUError) {
    image = try device.makeImage(ImageDescriptor(format: .rgba8, width: width, height: height,
                                                 usage: .renderTarget | .copySource | .copyDestination | .sampled))
    try makeDepth()
  }

  /// A window's three images, given to the window.
  func makeWindowImages(_ w: any GLWindow) throws(GPUError) {
    window = w
    var usage: ImageUsage = .renderTarget | .copySource | .copyDestination
    if device.limits.features.sampledImages { usage = usage | .sampled }
    for _ in 0..<3 {
      let frame = try device.makePresentImage(format: .bgra8, width: width, height: height, usage: usage)
      guard let vmo = frame.exportHandle(device) else {
        device.destroy(frame)
        throw .unsupported("a window's image: the device can't share it")
      }
      let counter = device.timelineHandle()
      guard let number = w.addImage(vmo: vmo, width: width, height: height, stride: frame.stridePixels, acquire: counter) else {
        device.destroy(frame)
        throw .unsupported("the compositor refused a window's image")
      }
      timeline = counter != nil
      frames.append(frame)
      windowImages.append(number)
    }
    try makeDepth()
  }

  /// eglSwapBuffers of a window: the frame submitted and presented, and the next image the one drawn into.
  func swap(_ frame: Frame) throws(GPUError) -> Bool {
    guard let w = window else {
      // A pbuffer's swap does nothing but end what was drawn.
      try frame.submit()
      return true
    }
    frame.endPass()
    let f = frames[current]
    frame.barrier(before: [f.image.handle])
    f.recordPresent(into: &frame.list)
    let drawn = try frame.submit()
    if !timeline && drawn > device.completed { try device.wait(drawn) }
    let outcome = w.present(windowImages[current], drawnAt: timeline ? drawn : nil, wait: swapInterval > 0)
    switch outcome {
    case .shown: framesShown += 1
    case .notTaken: framesDropped += 1
    case .lost: return false
    }
    // An image the compositor didn't take is free: the next frame is drawn into it again.
    if outcome == .notTaken { return true }
    // Else the next: one the compositor doesn't read.
    let shown = current
    var waited: UInt64 = 0
    while true {
      w.pump()
      for k in 1..<frames.count where w.isFree(windowImages[(shown + k) % frames.count]) {
        current = (shown + k) % frames.count
        serial &+= 1
        return true
      }
      guard waited < 5_000_000_000 else { return false }
      w.wait(nanoseconds: 1_000_000)
      waited += 1_000_000
    }
  }

  /// Gives everything back, once the GPU is past what was submitted.
  func release() {
    guard !destroyed else { return }
    destroyed = true
    if let frame = display.frame { try? frame.finish() }
    if let image { device.destroy(image) }
    if let depthImage { device.destroy(depthImage) }
    for (i, f) in frames.enumerated() {
      window?.removeImage(windowImages[i])
      device.destroy(f)
    }
    frames = []
    window?.close()
    window = nil
  }
}

public final class EGLContextObject {
  let display: EGLDisplayObject
  let config: EGLConfigInfo?
  let gl: GLContext
  var draw: EGLSurfaceObject?
  var destroyed = false
  init(display: EGLDisplayObject, config: EGLConfigInfo?, gl: GLContext) {
    self.display = display
    self.config = config
    self.gl = gl
  }
}

/// EGL's state: its objects by handle, its last error and what is current. A thread's state is the process's.
public final class EGLState: @unchecked Sendable {
  public static let shared = EGLState()
  let display = EGLDisplayObject()
  public var error: EGLint = EGL_SUCCESS
  var api: EGLenum = EGLenum(EGL_OPENGL_ES_API)
  var surfaces: [UInt: EGLSurfaceObject] = [:]
  var contexts: [UInt: EGLContextObject] = [:]
  var syncs: [UInt: UInt64] = [:]
  var nextHandle: UInt = 0x1000
  var current: EGLContextObject?

  /// The display handle: one, whatever display is asked for.
  static let displayHandle: UInt = 0xD15
  /// Config handles: their ids above this.
  static let configBase: UInt = 0xC0_0000

  func handle() -> UInt {
    nextHandle += 16
    return nextHandle
  }

  func fail(_ e: EGLint) { error = e }

  /// The display a handle names, initialized; nil with the error set where it isn't.
  func display(_ h: UnsafeMutableRawPointer?, initialized: Bool = true) -> EGLDisplayObject? {
    guard UInt(bitPattern: h) == EGLState.displayHandle else {
      fail(EGL_BAD_DISPLAY)
      return nil
    }
    guard !initialized || display.initialized else {
      fail(EGL_NOT_INITIALIZED)
      return nil
    }
    return display
  }

  func config(_ d: EGLDisplayObject, _ h: UnsafeMutableRawPointer?) -> EGLConfigInfo? {
    let v = UInt(bitPattern: h)
    guard v > EGLState.configBase, let c = d.config(EGLint(v - EGLState.configBase)) else {
      fail(EGL_BAD_CONFIG)
      return nil
    }
    return c
  }

  func surface(_ h: UnsafeMutableRawPointer?) -> EGLSurfaceObject? {
    guard let s = surfaces[UInt(bitPattern: h)] else {
      fail(EGL_BAD_SURFACE)
      return nil
    }
    return s
  }

  func context(_ h: UnsafeMutableRawPointer?) -> EGLContextObject? {
    guard let c = contexts[UInt(bitPattern: h)] else {
      fail(EGL_BAD_CONTEXT)
      return nil
    }
    return c
  }

  func handle(of s: EGLSurfaceObject?) -> UnsafeMutableRawPointer? {
    guard let s else { return nil }
    for (h, x) in surfaces where x === s { return unsafe UnsafeMutableRawPointer(bitPattern: h) }
    return nil
  }

  func handle(of c: EGLContextObject?) -> UnsafeMutableRawPointer? {
    guard let c else { return nil }
    for (h, x) in contexts where x === c { return unsafe UnsafeMutableRawPointer(bitPattern: h) }
    return nil
  }

  // MARK: Calls

  func createPbuffer(_ d: EGLDisplayObject, _ c: EGLConfigInfo, _ attributes: [(EGLint, EGLint)]) -> UnsafeMutableRawPointer? {
    var width: EGLint = 0, height: EGLint = 0
    for (a, v) in attributes {
      switch a {
      case EGL_WIDTH: width = v
      case EGL_HEIGHT: height = v
      case EGL_LARGEST_PBUFFER, EGL_TEXTURE_FORMAT, EGL_TEXTURE_TARGET, EGL_MIPMAP_TEXTURE, EGL_GL_COLORSPACE, EGL_VG_ALPHA_FORMAT,
        EGL_VG_COLORSPACE:
        break
      default:
        fail(EGL_BAD_ATTRIBUTE)
        return nil
      }
    }
    guard width >= 0, height >= 0 else {
      fail(EGL_BAD_PARAMETER)
      return nil
    }
    let s = EGLSurfaceObject(display: d, config: c, width: max(width, 1), height: max(height, 1))
    do throws(GPUError) { try s.makePbuffer() } catch {
      say("a pbuffer: \(error)")
      fail(EGL_BAD_ALLOC)
      return nil
    }
    let h = handle()
    surfaces[h] = s
    return unsafe UnsafeMutableRawPointer(bitPattern: h)
  }

  /// A window surface for the window `native` describes (a `struct vectra_egl_window`).
  func createWindow(_ d: EGLDisplayObject, _ c: EGLConfigInfo, _ native: UnsafeRawPointer?, _ attributes: [(EGLint, EGLint)])
    -> UnsafeMutableRawPointer?
  {
    guard let native = unsafe native else {
      fail(EGL_BAD_NATIVE_WINDOW)
      return nil
    }
    for (a, v) in attributes {
      switch a {
      case EGL_RENDER_BUFFER:
        guard v == EGL_BACK_BUFFER else {
          fail(EGL_BAD_MATCH)
          return nil
        }
      case EGL_GL_COLORSPACE, EGL_VG_ALPHA_FORMAT, EGL_VG_COLORSPACE: break
      default:
        fail(EGL_BAD_ATTRIBUTE)
        return nil
      }
    }
    let width = Int32(truncatingIfNeeded: unsafe native.load(as: UInt32.self))
    let height = Int32(truncatingIfNeeded: unsafe native.load(fromByteOffset: 4, as: UInt32.self))
    let titlePointer = unsafe native.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self)
    let title = unsafe cString(titlePointer) ?? ""
    let flags = unsafe native.load(fromByteOffset: 16, as: UInt32.self)
    guard width > 0, height > 0 else {
      fail(EGL_BAD_NATIVE_WINDOW)
      return nil
    }
    // Headless (VECTRA_EGL_WINDOW_HEADLESS): no compositor shows it, so its image is the surface's own, as a
    // pbuffer's is, and a swap only ends the frame.
    if flags & 1 != 0 {
      let s = EGLSurfaceObject(display: d, config: c, width: width, height: height)
      do throws(GPUError) { try s.makePbuffer() } catch {
        say("a headless window surface: \(error)")
        s.release()
        fail(EGL_BAD_ALLOC)
        return nil
      }
      let h = handle()
      surfaces[h] = s
      return unsafe UnsafeMutableRawPointer(bitPattern: h)
    }
    guard let platform = unsafe glPlatform else {
      fail(EGL_BAD_NATIVE_WINDOW)
      return nil
    }
    guard let w = platform.openWindow(title: title, width: width, height: height) else {
      say("no window: is the compositor running?")
      fail(EGL_BAD_NATIVE_WINDOW)
      return nil
    }
    let s = EGLSurfaceObject(display: d, config: c, width: w.width, height: w.height)
    do throws(GPUError) { try s.makeWindowImages(w) } catch {
      say("a window surface: \(error)")
      s.release()
      fail(EGL_BAD_ALLOC)
      return nil
    }
    let h = handle()
    surfaces[h] = s
    return unsafe UnsafeMutableRawPointer(bitPattern: h)
  }

  func createContext(_ d: EGLDisplayObject, _ c: EGLConfigInfo?, share: EGLContextObject?, _ attributes: [(EGLint, EGLint)])
    -> UnsafeMutableRawPointer?
  {
    guard api == EGLenum(EGL_OPENGL_ES_API) else {
      fail(EGL_BAD_MATCH)
      return nil
    }
    var version: EGLint = 1
    for (a, v) in attributes {
      switch a {
      case EGL_CONTEXT_CLIENT_VERSION: version = v
      case 0x30FB: if v != 0 { version = v * 100 }  // EGL_CONTEXT_MINOR_VERSION: 2.0 only
      case 0x30FC, 0x31BD, EGL_CONTEXT_OPENGL_ROBUST_ACCESS, EGL_CONTEXT_OPENGL_DEBUG: break  // flags: none taken
      default:
        fail(EGL_BAD_ATTRIBUTE)
        return nil
      }
    }
    // OpenGL ES 2.0 only: a 1.x or 3.x context isn't made.
    guard version == 2 else {
      fail(EGL_BAD_MATCH)
      return nil
    }
    guard let frame = d.frame else {
      fail(EGL_NOT_INITIALIZED)
      return nil
    }
    let gl = GLContext(frame: frame, share: share?.gl.share)
    let h = handle()
    contexts[h] = EGLContextObject(display: d, config: c, gl: gl)
    return unsafe UnsafeMutableRawPointer(bitPattern: h)
  }

  func makeCurrent(_ context: EGLContextObject?, draw: EGLSurfaceObject?) {
    if let old = current, old !== context {
      old.gl.frame.endPass()
      old.draw?.boundContext = nil
      if let s = old.draw, s.destroyed == false, surfaces.values.contains(where: { $0 === s }) == false { s.release() }
      if old.destroyed { contexts = contexts.filter { $0.value !== old } }
    }
    current = context
    unsafe currentContext = context?.gl
    guard let context else { return }
    if let d = context.draw, d !== draw { context.gl.frame.endPass() }
    context.draw = draw
    draw?.boundContext = context
    context.gl.madeCurrent(draw)
  }

  func destroySurface(_ h: UnsafeMutableRawPointer?) -> Bool {
    guard let s = unsafe surface(h) else { return false }
    surfaces[UInt(bitPattern: h)] = nil
    // Current to a context: it goes when that context is released.
    if s.boundContext == nil || s.boundContext !== current { s.release() }
    return true
  }

  func destroyContext(_ h: UnsafeMutableRawPointer?) -> Bool {
    guard let c = unsafe context(h) else { return false }
    c.destroyed = true
    if c !== current { contexts[UInt(bitPattern: h)] = nil }
    return true
  }
}
