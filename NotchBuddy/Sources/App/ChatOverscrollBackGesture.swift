import SwiftUI
import AppKit

// MARK: - "Is the active ScrollView at the bottom?" check
//
// `IslandContentView` keeps every island view in its view tree at once
// (just `opacity 0` for inactive ones) so the crossfade animation works.
// That means every inactive `ScrollView` keeps firing its
// `onScrollGeometryChange` callback too — an Upload/Mail/etc. ScrollView
// that hasn't been read to the bottom would mask the active chat view's
// true state if we used PreferenceKey reduction.
//
// We side-step that by writing directly to `state.scrollAtBottom` from
// each ScrollView, gated on the ScrollView's own view being the active
// one. Inactive ScrollViews are ignored entirely; active ones always
// own the value. The default `true` in AppState covers the home view
// (which has no ScrollView at all).

/// Apply to a `ScrollView` to publish "am I at the bottom" into
/// `state.scrollAtBottom`. The `onlyWhenActive` view identifies which
/// `IslandView` this ScrollView belongs to; the modifier only writes
/// to state when that view is the active one. The predicate handles
/// short content (`contentSize <= containerSize` is trivially "at the
/// bottom") so views like PromptView with only a couple of lines still
/// allow the gesture.
struct ReportsScrollAtBottom: ViewModifier {
    @ObservedObject var state: AppState
    let onlyWhenActive: IslandView

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geo in
                let extra = geo.contentSize.height - geo.containerSize.height
                if extra <= 0 { return true }
                // 1pt slack covers floating-point jitter at the boundary.
                return geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 1
            } action: { _, newValue in
                // Only the active view's ScrollView is allowed to set the
                // gate — otherwise an inactive sibling would mask the
                // chat view's true state.
                guard state.view == onlyWhenActive else { return }
                if state.scrollAtBottom != newValue {
                    state.scrollAtBottom = newValue
                }
            }
    }
}

extension View {
    /// Track this ScrollView's bottom state via `onScrollGeometryChange`
    /// and write it to `state.scrollAtBottom`, but only while this
    /// ScrollView's containing `IslandView` is the active one.
    func reportsScrollAtBottomViaGeometry(for view: IslandView, state: AppState) -> some View {
        modifier(ReportsScrollAtBottom(state: state, onlyWhenActive: view))
    }
}

// MARK: - Overscroll-back-to-home-or-collapse gesture
//
// Default enabled, no settings toggle (per the BoringNotch-style request).
// Adapts BoringNotch's `panGesture(direction:)` mechanism, which:
//
//   * Installs an `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)`.
//   * Filters events by `event.window === state.islandWindow` so we only
//     react to scrolls on the island's own panel — a local monitor otherwise
//     picks up scrolls from every foreground window in the app process.
//   * Requires the configured axis to dominate: vertical scroll must be at
//     least 1.5× the horizontal component (and vice-versa) to filter out
//     diagonal noise from a wobbly two-finger swipe.
//   * Multiplies non-precise (mouse-wheel) deltas by 8 so they feel similar
//     to trackpad gestures (BoringNotch value).
//   * Accumulates upward deltas (`event.scrollingDeltaY < 0`, i.e. content
//     moves up under the user's fingers); fires once the running total
//     crosses `triggerThreshold` points. This sign convention matches
//     BoringNotch's `PanDirection.up`, which the user has confirmed feels
//     like a natural "swipe up".
//
// Once the threshold is crossed:
//   - `.prompt`  → switch to `.overview` (with the same spring as the rest
//     of the island's transitions).
//   - `.overview` → post `.islandCollapse` so `IslandWindowController` runs
//     the canonical collapse path (animation + close sound).
//
// A downward scroll of at least `resetThreshold` points clears the accumulator
// so the user can abandon an in-progress gesture.
//
// `.began` / `.changed` / `.ended` are intentionally collapsed: Coucou does
// not animate the gesture live (no drag preview), so a single fire-and-reset
// is enough.

struct OverscrollBackGesture: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content.background(ScrollWheelMonitor(state: state))
    }
}

extension View {
    /// Attach the upward-overscroll gesture (always on, no settings toggle).
    func overscrollBackGesture(state: AppState) -> some View {
        modifier(OverscrollBackGesture(state: state))
    }
}

private struct ScrollWheelMonitor: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeNSView(context: Context) -> NSView {
        // Don't bother inserting a real NSView — we read islandWindow out of
        // state, not from this background view. Returning a zero-frame view
        // keeps SwiftUI's `.background(...)` happy without adding any kind
        // of hit-target that could swallow scroll events on the island.
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.installIfNeeded(state: state)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        // Cumulative upward scroll in points; cleared on fire or on a strong
        // downward scroll.
        private var accumulated: CGFloat = 0

        // During the cooldown window after a fire, ignore incoming events.
        // This separates "swipe from chat back to home" from "swipe from
        // home to collapse" so a single trackpad gesture can't trigger both.
        private var cooldownUntil: Date = .distantPast

        // After 300 ms with no scroll events, treat the gesture as ended
        // so a half-completed swipe doesn't linger waiting on more input.
        private var endTask: Task<Void, Never>?

        // Tunables (BoringNotch-aligned defaults, raised for the gesture
        // sensitivity we agreed on with the user).
        // Home view: keep it short — a single quick swipe collapses the
        // island, matching the BoringNotch ergonomic.
        private static let triggerThreshold: CGFloat = 40
        // Chat view: noticeably longer so the user keeps reading without
        // accidentally bouncing out of a long thread.
        private static let chatTriggerThreshold: CGFloat = 160
        private static let resetThreshold: CGFloat = 16
        private static let endTimeoutMs: Int = 300
        private static let axisDominanceFactor: CGFloat = 1.5
        private static let noiseThreshold: CGFloat = 0.2
        private static let nonPreciseScale: CGFloat = 8
        // A single trackpad swipe fires a stream of NSEvent.scrollWheel
        // events spanning ~250 ms. Without a cooldown, hitting the chat
        // threshold would immediately start counting toward the home
        // threshold in the same gesture — collapsing the island before the
        // user even sees the home view. After firing we ignore scrolls for
        // this window so the two steps stay distinct.
        private static let cooldownMs: Int = 600

        func installIfNeeded(state: AppState) {
            guard monitor == nil else { return }
            // We need islandWindow to be set before events can possibly route
            // here, but install as early as possible so we don't miss events.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self = self else { return event }
                MainActor.assumeIsolated {
                    self.handleScroll(event: event, state: state)
                }
                return event
            }
        }

        func uninstall() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
            endTask?.cancel()
            endTask = nil
            accumulated = 0
        }

        private func scheduleEndTimeout() {
            endTask?.cancel()
            endTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.endTimeoutMs))
                guard let self = self, !Task.isCancelled else { return }
                self.accumulated = 0
            }
        }

        @MainActor
        private func handleScroll(event: NSEvent, state: AppState) {
            // Cooldown window after the last fire: drop the event entirely
            // so a single trackpad swipe can only trigger one step.
            guard Date() >= cooldownUntil else { return }

            // BoringNotch's gating: only react to scrolls that target the
            // island's panel. Without this we'd also claim scrolls from
            // any other window in this app's process.
            guard event.window === state.islandWindow else { return }

            // Only meaningful while the island is expanded.
            guard state.mode == .expanded else { return }

            // The overview's right card is a ScrollView (active Claude
            // sessions). Scrolling inside it should never collapse the
            // island — the scroll wheel belongs to the list, not the
            // collapse gesture. The right card sits in the right half of
            // the island window; ignore any wheel event that lands there.
            // `event.locationInWindow` is window-local (origin at the
            // window's bottom-left); compare against the window's own width.
            if let win = state.islandWindow,
               event.locationInWindow.x > win.frame.width / 2 {
                accumulated = 0
                return
            }

            // Pick the gesture axis: vertical only. We only handle up-swipe
            // for now (matching BoringNotch's `.up` panGesture close path).
            let absDX = abs(event.scrollingDeltaX)
            let absDY = abs(event.scrollingDeltaY)
            guard absDY >= Self.axisDominanceFactor * absDX else { return }

            // The gesture is gated on "every nested ScrollView is at the
            // bottom" (or there is none at all). This is the user's
            // "信息已经触底了" precondition — without it the gesture
            // would also fire mid-thread, which is what tripped them up.
            guard state.scrollAtBottom else {
                accumulated = 0
                return
            }

            // Up: content moves up under the user's fingers, i.e.
            // `scrollingDeltaY < 0` in Cocoa's natural convention. The
            // opposite sign (positive) is downward — let the user cancel
            // an in-progress swipe.
            guard event.scrollingDeltaY < 0 else {
                if accumulated > 0,
                   abs(event.scrollingDeltaY) >= Self.resetThreshold {
                    accumulated = 0
                }
                return
            }

            // Scale non-precise deltas (mouse wheel) so they feel like trackpad.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : Self.nonPreciseScale
            let dy = -event.scrollingDeltaY * scale  // make positive
            guard dy > Self.noiseThreshold else { return }

            accumulated += dy
            scheduleEndTimeout()

            // Different thresholds per view: the chat view needs a longer
            // swipe so we don't accidentally bounce a user out of a long
            // thread they're still reading.
            let required = state.view == .prompt ? Self.chatTriggerThreshold : Self.triggerThreshold
            if accumulated >= required {
                accumulated = 0
                fire(state: state)
            }
        }

        @MainActor
        private func fire(state: AppState) {
            // Lock out follow-up scrolls long enough for the spring/collapse
            // animation to finish and the user to register the new view, but
            // short enough that a deliberate second swipe still works.
            cooldownUntil = Date().addingTimeInterval(TimeInterval(Self.cooldownMs) / 1000)
            switch state.view {
            case .prompt:
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.view = .overview
                }
            case .overview:
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            default:
                break
            }
        }
    }
}
