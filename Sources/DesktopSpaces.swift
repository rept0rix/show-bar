import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

enum DesktopSpaces {
    struct Desk: Equatable {
        let id: UInt64
        let index: Int
        var title: String { "Desktop \(index)" }
    }

    private static let skyLight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    static func desks() -> [Desk] {
        guard let connection = connectionID(),
              let copy: @convention(c) (Int32) -> Unmanaged<CFArray>? = symbol("SLSCopyManagedDisplaySpaces"),
              let unmanaged = copy(connection) else { return [] }
        let displays = unmanaged.takeRetainedValue() as NSArray
        var found: [Desk] = []
        for case let display as NSDictionary in displays {
            let spaces = display["Spaces"] as? [NSDictionary] ?? []
            for space in spaces {
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                guard type == 0 else { continue }
                let id = (space["id64"] as? NSNumber)?.uint64Value ?? 0
                guard id != 0, !found.contains(where: { $0.id == id }) else { continue }
                found.append(Desk(id: id, index: found.count + 1))
            }
        }
        return found
    }

    static func desk(for windowID: CGWindowID) -> Desk? {
        guard let spaceID = spaceID(for: windowID) else { return nil }
        return desks().first { $0.id == spaceID }
    }

    static func space(of windowID: CGWindowID) -> UInt64? {
        spaceID(for: windowID)
    }

    static func currentID() -> UInt64? {
        guard let connection = connectionID(),
              let copy: @convention(c) (Int32) -> Unmanaged<CFArray>? = symbol("SLSCopyManagedDisplaySpaces"),
              let unmanaged = copy(connection) else { return nil }
        let displays = unmanaged.takeRetainedValue() as NSArray
        for case let display as NSDictionary in displays {
            guard let current = display["Current Space"] as? NSDictionary else { continue }
            let id = (current["id64"] as? NSNumber)?.uint64Value ?? 0
            if id != 0 { return id }
        }
        return nil
    }

    static func move(windowID: CGWindowID, to spaceID: UInt64) {
        if bridgedMove(windowID: windowID, to: spaceID) { return }
        guard let connection = connectionID(),
              let move: @convention(c) (Int32, CFArray, UInt64) -> Void = symbol("SLSMoveWindowsToManagedSpace") else { return }
        let windows = [NSNumber(value: UInt32(windowID))] as CFArray
        move(connection, windows, spaceID)
    }

    private static let performOperation: (@convention(c) (UnsafeMutableRawPointer) -> Void)? = loadPerform()

    @discardableResult
    private static func bridgedMove(windowID: CGWindowID, to spaceID: UInt64) -> Bool {
        guard let performOperation else { return false }
        guard let objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW),
              let send = dlsym(objc, "objc_msgSend"),
              let opClass = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation") as? AnyClass else { return false }
        let alloc = unsafeBitCast(send, to: (@convention(c) (AnyClass, Selector) -> AnyObject).self)
        let raw = alloc(opClass, sel_getUid("alloc"))
        let initOp = unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject).self)
        let operation = initOp(raw, sel_getUid("initWithWindows:spaceID:"), [NSNumber(value: UInt32(windowID))], spaceID)
        performOperation(Unmanaged.passUnretained(operation).toOpaque())
        return true
    }

    private static func loadPerform() -> (@convention(c) (UnsafeMutableRawPointer) -> Void)? {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let needle = "SLSPerformAsynchronousBridgedWindowManagementOperation"
        let count = _dyld_image_count()
        for index in 0..<count {
            guard let name = _dyld_get_image_name(index), String(cString: name).contains("SkyLight"),
                  let rawHeader = _dyld_get_image_header(index) else { continue }
            let header = UnsafeRawPointer(rawHeader).assumingMemoryBound(to: mach_header_64.self)
            let slide = _dyld_get_image_vmaddr_slide(index)
            var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            var symtab: symtab_command?
            var linkedit: segment_command_64?
            for _ in 0..<header.pointee.ncmds {
                let command = cursor.assumingMemoryBound(to: load_command.self)
                if command.pointee.cmd == LC_SYMTAB {
                    symtab = cursor.assumingMemoryBound(to: symtab_command.self).pointee
                } else if command.pointee.cmd == UInt32(LC_SEGMENT_64) {
                    let segment = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
                    if String(cString: tupleBytes(segment.segname)) == "__LINKEDIT" {
                        linkedit = segment
                    }
                }
                cursor = cursor.advanced(by: Int(command.pointee.cmdsize))
            }
            guard let symtab, let linkedit else { continue }
            let base = UnsafeRawPointer(bitPattern: UInt(linkedit.vmaddr) + UInt(bitPattern: slide) - UInt(linkedit.fileoff))
            guard let base else { continue }
            let symbols = base.advanced(by: Int(symtab.symoff)).assumingMemoryBound(to: nlist_64.self)
            let strings = base.advanced(by: Int(symtab.stroff)).assumingMemoryBound(to: CChar.self)
            for symbolIndex in 0..<Int(symtab.nsyms) {
                let symbol = symbols[symbolIndex]
                if symbol.n_un.n_strx == 0 { continue }
                let symbolName = String(cString: strings.advanced(by: Int(symbol.n_un.n_strx)))
                guard symbolName.contains(needle), let address = UnsafeMutableRawPointer(bitPattern: UInt(symbol.n_value) + UInt(bitPattern: slide)) else { continue }
                return unsafeBitCast(address, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
            }
        }
        return nil
    }

    private static func tupleBytes(_ tuple: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> [CChar] {
        [tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7, tuple.8, tuple.9, tuple.10, tuple.11, tuple.12, tuple.13, tuple.14, tuple.15]
    }

    private static func spaceID(for windowID: CGWindowID) -> UInt64? {
        guard let connection = connectionID(),
              let copy: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>? = symbol("CGSCopySpacesForWindows") else { return nil }
        let windows = [NSNumber(value: UInt32(windowID))] as CFArray
        guard let unmanaged = copy(connection, 7, windows) else { return nil }
        let spaces = unmanaged.takeRetainedValue() as NSArray
        return (spaces.firstObject as? NSNumber)?.uint64Value
    }

    private static func connectionID() -> Int32? {
        guard let main: @convention(c) () -> Int32 = symbol("CGSMainConnectionID") else { return nil }
        let connection = main()
        return connection == 0 ? nil : connection
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let raw = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}
