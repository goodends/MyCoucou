import AppKit

/// A Space of our own, holding the island.
///
/// The island's panel is `.stationary`, and a stationary window slides with
/// the desktop when the user switches Spaces: the island would travel to
/// every desktop and show up in each one of them. Giving the panel a Space
/// that is not one of the user's desktops keeps it where it is — the desktop
/// slides, the island stays put.
///
/// The Space is made through SkyLight's private window-server calls. They
/// are looked up at runtime, so the app links against nothing private, and
/// every one of them can fail: without a Space of our own the island simply
/// keeps sliding with the desktop, as it always did.
@MainActor
final class IslandOverlaySpace {
    private typealias ConnectionID = UInt32
    private typealias CreateSpace = @convention(c) (ConnectionID, Int32, CFDictionary?) -> UInt64
    private typealias SpacesFunction = @convention(c) (ConnectionID, CFArray) -> Int32
    private typealias WindowsFunction = @convention(c) (ConnectionID, CFArray, CFArray) -> Void
    private typealias DestroySpace = @convention(c) (ConnectionID, UInt64) -> Void

    private let connection: ConnectionID
    private let space: UInt64
    private let show: SpacesFunction
    private let hide: SpacesFunction
    private let addWindows: WindowsFunction
    private let removeWindows: WindowsFunction
    private let destroy: DestroySpace

    /// The windows we put in the Space, by window number. The number is
    /// reused by the window server once a window is closed, so the window
    /// itself is kept alongside it.
    private var windows: [Int: NSWindow] = [:]
    private var closed = false

    /// The Space every overlay of the app lives in: the island, the bot on
    /// the desktop, the drag ghost.
    static let shared: IslandOverlaySpace? = IslandOverlaySpace()

    init?() {
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
        }
        guard let main = symbol("CGSMainConnectionID"),
              let create = symbol("CGSSpaceCreate"),
              let show = symbol("CGSShowSpaces"),
              let hide = symbol("CGSHideSpaces"),
              let add = symbol("CGSAddWindowsToSpaces"),
              let remove = symbol("CGSRemoveWindowsFromSpaces"),
              let destroy = symbol("CGSSpaceDestroy")
        else { return nil }

        let connection = unsafeBitCast(main, to: (@convention(c) () -> ConnectionID).self)()
        guard connection != 0 else { return nil }

        // The flags decide what the Space paints. 1 keeps it clear of the
        // desktop icons; any other flag makes Finder draw them in there.
        let space = unsafeBitCast(create, to: CreateSpace.self)(connection, 1, nil)
        guard space != 0 else { return nil }

        self.connection = connection
        self.space = space
        self.show = unsafeBitCast(show, to: SpacesFunction.self)
        self.hide = unsafeBitCast(hide, to: SpacesFunction.self)
        self.addWindows = unsafeBitCast(add, to: WindowsFunction.self)
        self.removeWindows = unsafeBitCast(remove, to: WindowsFunction.self)
        self.destroy = unsafeBitCast(destroy, to: DestroySpace.self)

        _ = self.show(connection, [NSNumber(value: space)] as CFArray)
    }

    /// Puts a window in our Space.
    ///
    /// A window that is already on screen keeps the desktop it was shown on
    /// and slides with it, so it is ordered out and in again around the move.
    /// A window that was never shown simply joins the Space.
    func add(_ window: NSWindow) {
        guard !closed else { return }
        let id = window.windowNumber
        guard id > 0 else { return }
        // Already ours: nothing to move.
        if let known = windows[id], known === window { return }
        let wasVisible = window.isVisible
        if wasVisible { window.orderOut(nil) }
        windows[id] = window
        addWindowsToSpace([id])
        if wasVisible { window.orderFrontRegardless() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if !windows.isEmpty {
            removeWindowsFromSpace(Array(windows.keys))
            windows.removeAll()
        }
        _ = hide(connection, [NSNumber(value: space)] as CFArray)
        destroy(connection, space)
    }

    private func addWindowsToSpace(_ ids: [Int]) {
        addWindows(connection,
                   ids.map { NSNumber(value: $0) } as CFArray,
                   [NSNumber(value: space)] as CFArray)
    }

    private func removeWindowsFromSpace(_ ids: [Int]) {
        removeWindows(connection,
                      ids.map { NSNumber(value: $0) } as CFArray,
                      [NSNumber(value: space)] as CFArray)
    }
}
