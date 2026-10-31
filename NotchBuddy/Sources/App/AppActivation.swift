import AppKit

/// Bringing another app to the front.
///
/// `NSRunningApplication.activate(options: .activateIgnoringOtherApps)` used
/// to be the way to do this, but that option is deprecated as of macOS 14 and
/// does nothing on macOS 15+. Without it the request is refused outright
/// (returns false) whenever the caller is itself the active app — which is
/// exactly the case while the settings window is up.
///
/// LaunchServices does not care who asks, so it is the way in: `open -b
/// <bundle id>` brings the app forward, and starts it when it is not running.
enum AppActivation {
    /// The app's URL, whether or not it is running.
    static func url(bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    /// Bring the app to the front, starting it if it is not running.
    @discardableResult
    static func activate(bundleId: String) -> Bool {
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId }),
           running.activate() {
            return true
        }
        return openViaLaunchServices(bundleId: bundleId)
    }

    /// Hand the request to LaunchServices. `open -b` targets a bundle id, so
    /// it finds the app wherever it is installed.
    @discardableResult
    static func openViaLaunchServices(bundleId: String) -> Bool {
        #if APPSTORE
        guard let url = url(bundleId: bundleId) else { return false }
        return NSWorkspace.shared.openApplication(at: url, configuration: .init())
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", bundleId]
        do {
            try p.run()
            return true
        } catch {
            return false
        }
        #endif
    }
}
