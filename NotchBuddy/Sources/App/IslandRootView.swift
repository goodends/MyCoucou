import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×320 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Island container

struct IslandContainer: View {
    @ObservedObject var state: AppState
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    // topRadius > 0 → convex expanded corners; < 0 → concave ear cutouts
    @State private var islandTopRadius: CGFloat = 0
    @State private var greetNotif: Bool = false

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase  = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    /// Fixed height for the chat (`.prompt`) island. Used to be a function of
    /// `focusTask.history.count`, which made the island grow every time the
    /// user sent a message and didn't even account for `ChatSessionView` whose
    /// messages come from JSONL — so a long session rendered in a 240px stub.

    /// Pixels the content must be pushed down to clear the concave ear transparent area.
    /// = 0 in expanded mode (no ears), = earRadius in compact/notch mode.
    private var earOffset: CGFloat { max(0, -islandTopRadius) }

    var body: some View {
        let greetingActive = state.mode == .expanded && state.view == .greeting

        return ZStack(alignment: .topLeading) {
            // Black island shape
            IslandShape(width: islandWidth, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius)
                .fill(Color.black)

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(.opacity)
                } else {
                    IslandContentView(state: state)
                        .frame(width: islandWidth, height: islandHeight - earOffset)
                        .offset(y: earOffset)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius))
                        .transition(.opacity)
                }
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during upload canvas or greeting (both draw their own Mochi).
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                // Keep idle animations inside the resting strip. Expanded views
                // retain the panel's full height for particles and hands.
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: islandWidth,
                                      height: state.mode == .expanded ? 320 : islandHeight)
                }
                .opacity(greetingActive ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: greetingActive)

            CountdownBar(state: state, islandW: islandWidth)

        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            let tr: CGFloat = 0
            withAnimation(anim) {
                islandWidth      = w
                islandHeight     = (newMode == .expanded && state.view == .prompt) ? IslandConst.chatHeight : h
                cornerRadius     = cr
                islandTopRadius  = tr
            }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            let (w, h) = islandSize(mode: .expanded, view: newView,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = newView == .prompt ? IslandConst.chatHeight : h
            }
        }
        .onChange(of: state.focusTask?.history.count ?? 0) { _, _ in
            guard state.mode == .expanded, state.view == .prompt else { return }
            withAnimation(openSpring) { islandHeight = IslandConst.chatHeight }
        }
        // Another session finishing — or a question arriving — stacks one more
        // card onto the inbox without changing the view or the mode, so neither
        // onChange above fires. Without this the cards pile up behind a frozen
        // height. Counts the inbox, not just the finished sessions: a question
        // row is just as tall.
        .onChange(of: state.inbox.count) { _, _ in
            guard state.mode == .expanded, state.view == .finished else { return }
            let (_, h) = islandSize(mode: .expanded, view: .finished,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) { islandHeight = h }
        }
        .onAppear {
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth      = w
            islandHeight     = state.view == .prompt ? IslandConst.chatHeight : h
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            islandTopRadius  = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            greetNotif.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandScreenChanged)) { _ in
            // New screen, new resting size (notch ↔ bar): snap without animation.
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth  = w
            islandHeight = (state.mode == .expanded && state.view == .prompt) ? IslandConst.chatHeight : h
        }
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// topRadius > 0  → convex rounded top corners (expanded mode)
// topRadius < 0  → concave ear cutouts, |topRadius| = ear radius (compact/notch mode)
// topRadius = 0  → sharp top corners (transient during animation)

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var topRadius: CGFloat      // see above

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(width, height), cornerRadius), topRadius) }
        set {
            width        = newValue.first.first.first
            height       = newValue.first.first.second
            cornerRadius = newValue.first.second
            topRadius    = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, cornerRadius)
        var p  = Path()

        if topRadius >= 0 {
            // ── Convex rounded top corners (expanded) ──────────────────────────
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            // Top-right convex corner
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            p.addLine(to: CGPoint(x: 0, y: tr))
            // Top-left convex corner
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // ── Concave ear cutouts (compact / notch) ─────────────────────────
            let er = -topRadius   // positive ear radius
            p.move(to: CGPoint(x: 0, y: 0))
            // Top-left ear
            p.addArc(center: CGPoint(x: 0, y: er), radius: er,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Top edge
            p.addLine(to: CGPoint(x: width - er, y: er))
            // Top-right ear
            p.addArc(center: CGPoint(x: width, y: er), radius: er,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge back to top-left corner
            p.addLine(to: CGPoint(x: 0, y: 0))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Bot placement helper

struct BotPlacement: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    var body: some View {
        // The finished view draws a Mochi per inbox row, for its own session —
        // so the single shared one would double up on the stack, and sit on
        // top of the empty state, which has nothing to show a character for.
        if state.view == .finished {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, hasNotch: state.hasNotch)
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = 40

        return Group {
            if state.mode == .expanded {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: botGlowColor(state.effectiveState), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 1.1
                    ))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                    .blur(radius: 6)
                    .opacity(botGlowOpacity(state.effectiveState))
                    .position(x: cx, y: cy)
                    .animation(.easeInOut(duration: 0.4), value: state.effectiveState)
            }

            // Normal: extra 40pt canvas at top for heart particles; position offset up by 20pt;
            // BotEngine compensates with cy = H/2 + particleOverhang/2 + oy*R + R*0.06.
            BotCanvasView(state: state, particleOverhang: overhang)
                .frame(width: canvasSize, height: canvasSize + overhang)
                .opacity(state.isDraggingBot || state.mochiOnDesktop ? 0 : opacity)
                .position(x: cx, y: cy - overhang / 2)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cx)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cy)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: canvasSize)
                .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
        }
        // Slap, drag, and hover are handled by the AppKit NSEvent monitor in
        // IslandWindowController — not SwiftUI gestures — so this is safe.
        .allowsHitTesting(false)
    }

    private func botGlowColor(_ s: BotState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color.white
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle, .sleeping: return 0.15
        case .dizzy:           return 0.0
        default:               return 0.65
        }
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, hasNotch: Bool = true) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact: return (20, resting.botCenterY, resting.botDiameter, 1)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Center of the fixed 84pt card (VStack top=8, header=34 → content starts at y=42)
            let headerBottom: CGFloat = 42
            let cardH: CGFloat = 84
            cy = headerBottom + (islandH - headerBottom - cardH) / 2 + cardH / 2
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Countdown bar

struct CountdownBar: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    @State private var barWidth: CGFloat = 0
    @State private var timer: Timer? = nil

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: barWidth, height: 2)
                .cornerRadius(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateBar()
        }
    }

    private func updateBar() {
        // A card that doesn't auto-close must not show a countdown promising a
        // folding that never comes.
        guard state.mode == .expanded && !state.isPinned && !state.holdsIslandOpen else {
            barWidth = 0
            return
        }
        let autoClose = state.autoCloseInterval
        let window = min(10.0, autoClose * 0.6)
        let elapsed = Date.now.timeIntervalSince(state.lastActivity)
        let remaining = autoClose - elapsed
        if remaining < window {
            barWidth = max(0, CGFloat(remaining / window) * 160)
        } else {
            barWidth = 0
        }
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: 34)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            ZStack {
                ForEach(IslandView.allCases, id: \.self) { v in
                    let active = state.view == v
                    // Views that fill available height instead of the fixed 98pt content frame:
                    // chat (prompt) and changes are always flexible; mail is flexible only when active so
                    // it doesn't push the ZStack taller when inactive. The finished view is tall for
                    // the same reason — its stack of notification cards scrolls past the cap.
                    let isTall = v == .prompt || v == .changes || v == .finished
                    let anim: Animation = active
                        ? .spring(response: 0.4, dampingFraction: 0.8).delay(0.16)
                        : .easeIn(duration: 0.16)
                    IslandViewContent(view: v, state: state)
                        .frame(maxWidth: .infinity)
                        .frame(height: isTall ? nil : 98)
                        .frame(minHeight: (isTall && !active) ? 0 : nil, maxHeight: isTall ? .infinity : nil)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.97)
                        .allowsHitTesting(active)
                        .animation(anim, value: state.view)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
        // Default-enabled BoringNotch-style gesture: only when the active
        // ScrollView is scrolled to its bottom, an upward swipe pops back
        // to home; on home, another upward swipe collapses the island.
        // Implementation in ChatOverscrollBackGesture.swift.
        .overscrollBackGesture(state: state)
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left: tab capsules
            HStack(spacing: 5) {
                TabButton(icon: "house.fill", view: .overview, state: state)
                TabButton(icon: "bubble.left.fill", view: .prompt, state: state)
            }
            .padding(.leading, 14)

            Spacer()

            // Right: action icons
            HStack(spacing: 8) {
                HStack(spacing: 14) {
                    // Finished sessions wait here until acknowledged. Same view
                    // the hook force-expands to, but reachable on demand, and
                    // badged with the count so an unnoticed finish is visible
                    // from any page.
                    TabButton(icon: "bell", view: .finished, state: state)
                        .overlay(alignment: .topTrailing) {
                            if !state.inbox.isEmpty {
                                NotificationBadge(count: state.inbox.count)
                                    .offset(x: 4, y: -3)
                            }
                        }
                        .help(String(localized: "Notifications"))

                    // Settings now pops up as a separate window — the in-island
                    // settings page (sound toggle, auto-close picker, Claude
                    // hook badge) is gone.
                    Button(action: {
                        NotificationCenter.default.post(name: .openFullSettings, object: nil)
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Settings…"))

                    // Hide the island entirely. Routes through the FSM so
                    // expanded → collapse → hiddenExternally is clean.
                    Button(action: {
                        NotificationCenter.default.post(name: .islandHide, object: nil)
                    }) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Hide island"))
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    @ObservedObject var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(
                    isOn ? Color(hex: "#1D1F23") :
                    isHovered ? Color.white.opacity(0.07) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Unacknowledged-finish counter riding the bell tab. Caps the digits at "9+"
/// so a burst of sessions can't stretch the header.
struct NotificationBadge: View {
    let count: Int

    private var label: String {
        count > 9 ? "9+" : String(count)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Color(hex: "#FFFFFF"))
            .padding(.horizontal, count > 9 ? 3 : 0)
            .frame(minWidth: 13, minHeight: 13)
            .background(Capsule().fill(Color(hex: "#F4505E")))
    }
}

