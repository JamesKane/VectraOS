import CEFI

/// The volume the loader was started from (the ESP), for reading croi's
/// files: `\croi\kernel.elf`, `\croi\bootfs.img`, `\croi\cmdline`.
///
/// Dropping it closes the volume through firmware, so it must be consumed
/// before ExitBootServices.
@safe struct BootVolume: ~Copyable {
    private let boot: BootServices
    private let root: UnsafeMutablePointer<EFI_FILE_PROTOCOL>

    init(image: EFI_HANDLE?, boot: BootServices) throws(LoaderError) {
        guard let image = unsafe image else { throw .unsupported("no loader image handle", 0) }
        let loaded = try unsafe boot.handleProtocol(.loadedImage, on: image, as: EFI_LOADED_IMAGE_PROTOCOL.self)
        guard let device = unsafe loaded.pointee.DeviceHandle else {
            throw .unsupported("loader image has no device handle", 0)
        }
        let fs = try unsafe boot.handleProtocol(.simpleFileSystem, on: device, as: EFI_SIMPLE_FILE_SYSTEM_PROTOCOL.self)
        var root: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
        let status = unsafe croi_efi_open_volume(fs, &root)
        guard status == EFI_SUCCESS, let root = unsafe root else { throw .firmware("OpenVolume", status) }
        self.boot = boot
        unsafe self.root = root
    }

    deinit {
        _ = unsafe croi_efi_file_close(root)
    }

    /// Reads `path` into memory from `allocate(size)`, which must return at
    /// least `size` bytes. Returns nil if the file doesn't exist.
    func read(
        _ path: StaticString, allocate: (Int) throws(LoaderError) -> UnsafeMutableRawPointer
    ) throws(LoaderError) -> (buffer: UnsafeMutableRawPointer, size: Int)? {
        var file: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
        var status = unsafe withUCS2(path) { name in unsafe croi_efi_file_open(root, &file, name) }
        if status == EFI_NOT_FOUND { return nil }
        guard status == EFI_SUCCESS, let file = unsafe file else { throw .firmware("open file", status) }
        defer { _ = unsafe croi_efi_file_close(file) }

        var size: UInt64 = 0
        status = unsafe croi_efi_file_size(file, &size)
        guard status == EFI_SUCCESS else { throw .firmware("file size", status) }
        guard size < 1 << 32 else { throw .unsupported("file too large", size) }

        let buffer = try unsafe allocate(max(Int(size), 1))
        try unsafe readAll(file, size, into: buffer)
        return unsafe (buffer, Int(size))
    }

    /// Each file one directory below `dir` (`\dtb\<vendor>\<board>.dtb`),
    /// read into pool memory and given to `accept` with its name, `vendor/file`
    /// in ASCII, until one is accepted: that one is returned, the caller's to
    /// free; the rest are freed. Files over `limit` bytes are skipped. Nil if
    /// `dir` doesn't exist or nothing is accepted.
    func find(
        under dir: StaticString, limit: Int,
        accept: (_ buffer: UnsafeRawPointer, _ size: Int, _ name: Span<UInt8>) -> Bool
    ) throws(LoaderError) -> (buffer: UnsafeMutableRawPointer, size: Int)? {
        var top: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
        let status = unsafe withUCS2(dir) { name in unsafe croi_efi_file_open(root, &top, name) }
        if status == EFI_NOT_FOUND { return nil }
        guard status == EFI_SUCCESS, let top = unsafe top else { throw .firmware("open directory", status) }
        defer { _ = unsafe croi_efi_file_close(top) }
        var found: (buffer: UnsafeMutableRawPointer, size: Int)? = nil
        var vendorName = InlineArray<48, UInt8>(repeating: 0)
        try unsafe forEachEntry(top) { (vendor, vendorChars, _, isDirectory) throws(LoaderError) -> Bool in
            guard isDirectory else { return true }
            var sub: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
            guard unsafe croi_efi_file_open(top, &sub, vendor) == EFI_SUCCESS, let sub = unsafe sub else { return true }
            defer { _ = unsafe croi_efi_file_close(sub) }
            let vendorCount = min(vendorChars, vendorName.count)
            for i in 0..<vendorCount { vendorName[i] = UInt8(truncatingIfNeeded: unsafe vendor[i]) }
            try unsafe forEachEntry(sub) { (file, fileChars, size, isDirectory) throws(LoaderError) -> Bool in
                guard !isDirectory, size > 0, size <= UInt64(limit) else { return true }
                var handle: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
                guard unsafe croi_efi_file_open(sub, &handle, file) == EFI_SUCCESS, let handle = unsafe handle else {
                    return true
                }
                defer { _ = unsafe croi_efi_file_close(handle) }
                let buffer = try unsafe boot.allocatePool(Int(size))
                try unsafe readAll(handle, size, into: buffer)
                var name = InlineArray<96, UInt8>(repeating: 0)
                var count = 0
                for i in 0..<vendorCount { name[count] = vendorName[i]; count += 1 }
                name[count] = UInt8(ascii: "/")
                count += 1
                for i in 0..<fileChars where count < name.count {
                    name[count] = UInt8(truncatingIfNeeded: unsafe file[i])
                    count += 1
                }
                if unsafe accept(UnsafeRawPointer(buffer), Int(size), name.span.extracting(0..<count)) {
                    unsafe found = (buffer, Int(size))
                    return false
                }
                unsafe boot.freePool(buffer)
                return true
            }
            return unsafe found == nil
        }
        return unsafe found
    }

    /// Calls `body` with each entry of directory `dir` but `.` and `..`:
    /// its NUL-terminated name, the name's length, its size and whether it
    /// is a directory, while `body` returns true.
    private func forEachEntry(
        _ dir: UnsafeMutablePointer<EFI_FILE_PROTOCOL>,
        _ body: (UnsafeMutablePointer<CHAR16>, Int, UInt64, Bool) throws(LoaderError) -> Bool
    ) throws(LoaderError) {
        // EFI_FILE_INFO: Size, FileSize, PhysicalSize, three EFI_TIMEs,
        // Attribute (0x10: a directory) at 72, then the name at 80.
        var info = InlineArray<512, UInt8>(repeating: 0)
        var span = info.mutableSpan
        try span.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) throws(LoaderError) in
            let base = bytes.baseAddress!
            while true {
                var size = UInt(bytes.count - 2)
                let status = unsafe croi_efi_file_read(dir, &size, base)
                guard status == EFI_SUCCESS, size > 80 else { return }  // the end, or an entry too long: stop
                unsafe base.storeBytes(of: 0, toByteOffset: Int(size), as: UInt16.self)
                let name = unsafe (base + 80).assumingMemoryBound(to: CHAR16.self)
                var chars = 0
                while unsafe name[chars] != 0 { chars += 1 }
                let dot = CHAR16(UInt8(ascii: "."))
                if unsafe name[0] == dot && (chars == 1 || (chars == 2 && name[1] == dot)) { continue }
                let isDirectory = unsafe base.load(fromByteOffset: 72, as: UInt64.self) & 0x10 != 0
                let fileSize = unsafe base.load(fromByteOffset: 8, as: UInt64.self)
                guard try unsafe body(name, chars, fileSize, isDirectory) else { return }
            }
        }
    }

    /// Reads `size` bytes of `file` into `buffer`.
    private func readAll(_ file: UnsafeMutablePointer<EFI_FILE_PROTOCOL>, _ size: UInt64, into buffer: UnsafeMutableRawPointer)
        throws(LoaderError)
    {
        var done: UInt64 = 0
        while done < size {
            var chunk = UInt(size - done)
            let status = unsafe croi_efi_file_read(file, &chunk, buffer + Int(done))
            guard status == EFI_SUCCESS, chunk > 0 else { throw .firmware("read file", status) }
            done += UInt64(chunk)
        }
    }

    /// Reads `path` into loader pool memory (freed with `freePool`).
    func readIntoPool(_ path: StaticString) throws(LoaderError) -> (buffer: UnsafeMutableRawPointer, size: Int)? {
        try unsafe read(path) { (size: Int) throws(LoaderError) in try unsafe boot.allocatePool(size) }
    }

    /// Reads `path` into fresh pages of memory type `type`.
    func readIntoPages(_ path: StaticString, type: EFI_MEMORY_TYPE) throws(LoaderError) -> (phys: UInt64, size: Int)? {
        let result = try unsafe read(path) { (size: Int) throws(LoaderError) in
            let pages = (UInt64(size) + pageSize - 1) / pageSize
            return unsafe UnsafeMutableRawPointer(bitPattern: UInt(try boot.allocatePages(pages, type: type)))!
        }
        guard let result = unsafe result else { return nil }
        return unsafe (UInt64(UInt(bitPattern: result.buffer)), result.size)
    }
}

/// Calls `body` with `text` as a NUL-terminated UCS-2 string. ASCII only,
/// at most 63 characters (a stack buffer: the loader has no heap).
func withUCS2<R>(_ text: StaticString, _ body: (UnsafeMutablePointer<CHAR16>) -> R) -> R {
    var buffer = InlineArray<64, CHAR16>(repeating: 0)
    precondition(text.utf8CodeUnitCount < buffer.count)
    text.withUTF8Buffer { utf8 in
        for i in 0..<utf8.count {
            buffer[i] = CHAR16(unsafe utf8[i])
        }
    }
    var span = buffer.mutableSpan
    return span.withUnsafeMutableBufferPointer { unsafe body($0.baseAddress!) }
}
