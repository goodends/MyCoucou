import CoreGraphics
import AppKit

/// Watches for clicks anywhere on the screen, so the island can fold when the
/// user clicks away from it.
///
/// `NSEvent`'s global monitor is no good here: it only fires while the app
/// is the active one, and the island is a non-activating panel — clicking it
/// never makes us active, so a click on the island and a click on another app
/// look identical to it. A session-level CGEvent tap sees every click,
/// whichever app has it.
///
/// Listen-only: the tap observes, it never swallows the event. A mouse click
/// needs no special permission to observe, and if the system refuses the tap
/// anyway the island simply keeps its current behaviour.
@MainActor
final class GlobalClickWatcher {
    static let shared = GlobalClickWatcher()

    /// Called with the click's position in screen coordinates (Quartz's
    /// bottom-left origin, like `NSEvent.mouseLocation`).
    var onClick: ((CGPoint) -> Void)?

    private var tap: CFMachPort?

    private init() {}

    /// The click's position in AppKit's screen coordinates.
    ///
    /// `CGEvent` hands out positions with the origin at the *top* of the
    /// primary screen and y growing downwards, while AppKit — and the
    /// island's own rectangle — counts from the bottom. On a 956pt-tall
    /// screen the same click comes back as y=73 from one and y=882 from the
    /// other, so without this flip every click lands a few pixels under the
    /// screen's top edge and reads as "far away from the island".
    static func appKitLocation(from eventLocation: CGPoint) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: eventLocation.x, y: primaryTop - eventLocation.y)
    }

    func start() {
        #if APPSTORE
        return
        #else
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in
                // The tap's source lives on the main run loop, so the callback
                // runs there too — the thread the island's state lives on.
                MainActor.assumeIsolated {
                    GlobalClickWatcher.shared.onClick?(
                        GlobalClickWatcher.appKitLocation(from: event.location)
                    )
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            appendAppLog("nb.log", "global click watcher: tap unavailable")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        #endif
    }
}
