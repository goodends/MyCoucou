import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var statusMessage: String = ""
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    /// True when the diff on screen removes things rather than adding them.
    @State private var pendingUninstall: Bool = false
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()

    #if !APPSTORE
    // The context bar on the overview card is read from Claude Code's statusline
    // payload, so it rides along with the hooks: same file, same diff, same
    // write, and no switch of its own — a checkbox that only took effect after
    // pressing a button elsewhere read as broken.
    @State private var contextUsageInstalled: Bool = StatusLineReader.isEnabled
    #endif

    #if !APPSTORE
    @State private var geminiHooksInstalled: Bool = HookServer.geminiHooksInstalled()
    @State private var showGeminiDiff: Bool = false
    @State private var pendingGeminiJSON: String = ""
    @State private var geminiPendingInstall: Bool = true

    @State private var agyHooksInstalled: Bool = HookServer.agyHooksInstalled()
    @State private var showAgyDiff: Bool = false
    @State private var pendingAgyJSON: String = ""
    @State private var agyPendingInstall: Bool = true

    @State private var codexHooksInstalled: Bool = HookServer.codexHooksInstalled()
    @State private var showCodexDiff: Bool = false
    @State private var pendingCodexJSON: String = ""
    @State private var codexPendingInstall: Bool = true

    @State private var copilotHooksInstalled: Bool = HookServer.copilotHooksInstalled()
    @State private var showCopilotDiff: Bool = false
    @State private var pendingCopilotJSON: String = ""
    @State private var copilotPendingInstall: Bool = true

    @State private var museHooksInstalled: Bool = HookServer.museHooksInstalled()
    @State private var showMuseDiff: Bool = false
    @State private var pendingMuseJSON: String = ""
    @State private var musePendingInstall: Bool = true

    @State private var openCodePluginInstalled: Bool = HookServer.openCodePluginInstalled()
    @State private var showOpenCodeDiff: Bool = false
    @State private var pendingOpenCodeContent: String = ""
    @State private var openCodePendingInstall: Bool = true

    @State private var ampPluginInstalled: Bool = HookServer.ampPluginInstalled()
    @State private var showAmpDiff: Bool = false
    @State private var pendingAmpContent: String = ""
    @State private var ampPendingInstall: Bool = true

    @State private var hermesPluginInstalled: Bool = HookServer.hermesPluginInstalled()
    @State private var showHermesPluginDiff: Bool = false
    @State private var pendingHermesPluginContent: String = ""
    @State private var hermesPluginPendingInstall: Bool = true

    @State private var showHermesConfigDiff: Bool = false
    @State private var pendingHermesConfigContent: String = ""
    @AppStorage("hermesApprovalsEnabled") private var hermesApprovalsEnabled: Bool = false
    @State private var hermesSupportsApprovals: Bool = false
    #endif

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    // Startup
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)

    // Bindings in seconds for the absence field
    private var absenceSeconds: Binding<Double> {
        Binding(
            get: { state.absenceInterval },
            set: { state.absenceInterval = max(1, $0) }
        )
    }

    // Connected screens for the Display picker, refreshed when screens change
    @State private var connectedScreens: [(uuid: String, name: String)] = []

    // Sidebar selection persisted across sessions
    @AppStorage("settingsSection") private var selectedSection: String = "general"
    // Active pills: the pill whose colour palette is open, if any
    @State private var colorPalettePill: String? = nil
    @AppStorage(ClaudeHost.terminalCardsKey) private var terminalCardsEnabled = false
    @State private var customSoundCount = SoundEngine.shared.customized.count

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — 200 pt, sidebar visual effect background
            ZStack(alignment: .topLeading) {
                SidebarBackground()
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(alignment: .center, spacing: 10) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("MyCoucou")
                                .font(.system(size: 13, weight: .semibold))
                            Text(appVersion)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                    Divider()
                    List(selection: Binding(
                        get: { Optional(selectedSection) },
                        set: { if let v = $0 { selectedSection = v; statusMessage = "" } }
                    )) {
                        SettingsSidebarRow(title: "General",      icon: "gearshape.fill",                    color: "#8E939C").tag("general")
                        SettingsSidebarRow(title: "Agents",       icon: "terminal.fill",                     color: "#3B9EFF").tag("agents")
                        SettingsSidebarRow(title: "Apps",         icon: "square.grid.2x2.fill",               color: "#10B981").tag("apps")
                        SettingsSidebarRow(title: "Shortcuts",    icon: "keyboard.fill",                     color: "#6366F1").tag("shortcuts")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 200)

            Divider()

            // Detail panel
            VStack(alignment: .leading, spacing: 0) {
                Text(sectionTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                if !statusMessage.isEmpty {
                    Divider()
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear {
        }
    }

    // MARK: - Section routing

    private var sectionTitle: String {
        switch selectedSection {
        case "general":      return String(localized: "General")
        case "agents":       return String(localized: "Agents")
        case "apps":         return String(localized: "Apps", defaultValue: "Apps")
        case "shortcuts":    return String(localized: "Shortcuts")
        default:             return String(localized: "General")
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case "agents":       agentsSection
        case "apps":         appsSection
        case "shortcuts":    ShortcutsSettingsView()
        default:             generalSection
        }
    }

    // MARK: - Apps section

    /// Which apps the notch lists Claude Code sessions for.
    ///
    /// "All" is the default and hides the list: with nothing filtered there is
    /// nothing to configure, and an unticked box reads as "don't filter on
    /// this" — never as "filter the other way round". Choosing "custom" reveals
    /// the list *and* a labelled rule for what the ticks mean, so the direction
    /// is stated next to the checkboxes instead of being implied by the one
    /// above them.
    @ViewBuilder private var appsSection: some View {
        GroupBox(String(localized: "Claude Code sessions")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { !state.showsAllHosts },
                    set: { custom in state.showsAllHosts = !custom }
                )) {
                    Text(String(localized: "apps.all", defaultValue: "All")).tag(false)
                    Text(String(localized: "apps.custom", defaultValue: "Custom")).tag(true)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()

                if state.showsAllHosts {
                    Text(String(localized: "apps.explain-all",
                                defaultValue: "Every app's Claude Code sessions are shown, notified and answered in the notch."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("", selection: $state.hostFilterRule) {
                        Text(String(localized: "apps.rule-show-only", defaultValue: "Show only the ticked")).tag(ClaudeHost.FilterRule.showOnly)
                        Text(String(localized: "apps.rule-exclude", defaultValue: "Exclude the ticked")).tag(ClaudeHost.FilterRule.exclude)
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    .labelsHidden()
                    Text(state.hostFilterRule == .showOnly
                         ? String(localized: "apps.explain-show-only",
                                  defaultValue: "Only the ticked apps show their Claude Code sessions, questions and permission requests. The rest stay silent.")
                         : String(localized: "apps.explain-exclude",
                                  defaultValue: "The ticked apps stay silent: no sessions in the list, no notifications, and their questions and permission requests are asked in the app itself. Every other app is shown."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    appHostRows
                    Text(String(localized: "apps.other-note",
                                defaultValue: "Sessions from an app we can't name land in Other."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
        // The boxes in General are as wide as the widest thing they hold (a
        // Slider). Nothing here is, so this one used to shrink to the width of
        // two radio buttons and the same card looked a different size from the
        // one above it. Full width like the rest.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The rows, split by kind. Orca and Other stand alone — one row each, so a
    /// header over them would only add noise.
    @ViewBuilder private var appHostRows: some View {
        ForEach(ClaudeHost.allHosts) { host in
            if host.group == .terminal || host.group == .editor,
               let firstOfGroup = ClaudeHost.allHosts.first(where: { $0.group == host.group }),
               firstOfGroup.id == host.id {
                Text(host.group == .terminal
                     ? String(localized: "Terminals", defaultValue: "Terminals")
                     : String(localized: "Editors", defaultValue: "Editors"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            Toggle(host.name, isOn: Binding(
                get: { state.hostFilterIds.contains(host.id) },
                set: { on in
                    if on { state.hostFilterIds.insert(host.id) }
                    else   { state.hostFilterIds.remove(host.id) }
                }
            ))
        }
    }

    // MARK: - General section

    @ViewBuilder private var generalSection: some View {
        GroupBox("Sound") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable sounds", isOn: $state.soundEnabled)
                HStack(spacing: 8) {
                    Text("Volume")
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $state.soundVolume, in: 0...0.2)
                        .disabled(!state.soundEnabled)
                    Text("\(Int(state.soundVolume / 0.2 * 100)) %")
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Button("Open sounds folder") { SoundEngine.shared.revealCustomFolder() }
                    Button("Reload sounds") {
                        SoundEngine.shared.reload()
                        customSoundCount = SoundEngine.shared.customized.count
                        SoundEngine.shared.play("pop")
                    }
                    if customSoundCount > 0 {
                        Text(String(format: String(localized: "%lld custom"), Int64(customSoundCount)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!state.soundEnabled)
                Text("Drop a file named like one of Mochi's sounds (finish.wav, approval.mp3, greet.m4a…) in the sounds folder to replace it, then Reload.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }

        GroupBox("Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Open on hover", isOn: $state.openOnHover)
                    .help("Hovering the island opens it; it folds again shortly after the pointer leaves. Click inside to keep it open.")
                HStack(spacing: 8) {
                    Text("Close after")
                    TextField("60", value: $state.autoCloseInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("s inactive")
                }
                HStack(spacing: 8) {
                    Text("Hide after")
                    TextField("60", value: absenceSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("s without movement")
                }
                Divider()
                // Belongs here rather than under the hooks: it is how the app
                // answers events it already receives, not something installing
                // an integration sets up.
                Toggle(String(localized: "hooks.terminal-cards",
                              defaultValue: "Answer questions and permissions from terminal sessions in the notch"),
                       isOn: $terminalCardsEnabled)
                Text(String(localized: "hooks.terminal-cards-explain",
                            defaultValue: "Off: sessions in Warp, Terminal, iTerm… show in the notch, but their questions and permission requests are asked in the terminal. On: the notch shows them first, and the terminal waits until you answer there or close the island (up to 2 min)."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }

        GroupBox("Display") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Show Mochi on", selection: $state.islandDisplay) {
                    Text("Screen with the notch").tag(IslandDisplayChoice.notch)
                    Text("Main screen (menu bar)").tag(IslandDisplayChoice.menuBar)
                    Text("Follow the mouse").tag(IslandDisplayChoice.followMouse)
                    Divider()
                    ForEach(connectedScreens, id: \.uuid) { screen in
                        Text(screen.name).tag(IslandDisplayChoice.display(uuid: screen.uuid))
                    }
                    if case .display(let uuid) = state.islandDisplay,
                       !connectedScreens.contains(where: { $0.uuid == uuid }) {
                        Text("Saved screen (not connected)").tag(state.islandDisplay)
                    }
                }
                .frame(maxWidth: 360)
                Text("On a screen without a notch, Mochi sits in a small bar at the top. Follow the mouse moves it to your cursor's screen while it is closed.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .onAppear { refreshConnectedScreens() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)) { _ in
                refreshConnectedScreens()
            }
        }

        GroupBox("Hotkey") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show island with shortcut", isOn: $state.hotkeyEnabled)
                    .onChange(of: state.hotkeyEnabled) { _, _ in
                        HotKeyCenter.shared.reregister(.toggleIsland)
                    }
                if state.hotkeyEnabled {
                    HStack(spacing: 8) {
                        Text("Shortcut")
                            .frame(width: 70, alignment: .leading)
                        ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                            .onChange(of: hotkeyFlags) { _, v in
                                state.hotkeyFlags = v
                                HotKeyCenter.shared.reregister(.toggleIsland)
                            }
                            .onChange(of: hotkeyCode) { _, v in
                                state.hotkeyCode = v
                                HotKeyCenter.shared.reregister(.toggleIsland)
                            }
                        Text("presses this → island opens")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(6)
        }

        GroupBox("Startup") {
            Toggle("Launch at Mac startup", isOn: $launchAtStartup)
                .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
                .padding(6)
        }

        GroupBox(String(localized: "Language")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $state.appLanguage) {
                    Text(String(localized: "System")).tag("")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                    Text("हिन्दी").tag("hi")
                    Text("Español").tag("es")
                    Text("العربية").tag("ar")
                    Text("Français").tag("fr")
                    Text("বাংলা").tag("bn")
                    Text("Português (Brasil)").tag("pt-BR")
                    Text("Русский").tag("ru")
                    Text("Bahasa Indonesia").tag("id")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: state.appLanguage) { _, code in
                    if code.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([code], forKey: "AppleLanguages")
                    }
                    UserDefaults.standard.synchronize()
                }
                HStack(spacing: 8) {
                    Button(String(localized: "Restart MyCoucou")) {
                        let appPath = Bundle.main.bundleURL.path
                        let pid = ProcessInfo.processInfo.processIdentifier
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/bin/sh")
                        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$1\"", "--", appPath]
                        try? task.run()
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                    Text(String(localized: "Applies on next launch"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(6)
        }

        }

    private func refreshConnectedScreens() {
        connectedScreens = NSScreen.screens.compactMap { screen in
            guard let uuid = IslandWindowController.displayUUID(screen) else { return nil }
            return (uuid, screen.localizedName)
        }
    }

    // MARK: - Agents section

    @ViewBuilder private var agentsSection: some View {
        GroupBox(String(localized: "hooks.claude-code.title")) {
            VStack(alignment: .leading, spacing: 10) {
                if hookNeedsUpdate {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(String(localized: "hooks.outdated"))
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    #if APPSTORE
                    Button(String(localized: "hooks.update")) { installHooksAppStore() }
                    #else
                    Button(String(localized: "hooks.update")) { installHooks() }
                    #endif
                }
                #if APPSTORE
                Text("~/.claude/coucou/nb-hook")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { installHooksAppStore() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { uninstallHooksAppStore() }
                        .buttonStyle(.bordered)
                }
                #else
                Text("nb-hook : \(HookServer.hookScriptPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { installHooks() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { uninstallHooks() }
                        .buttonStyle(.bordered)
                }
                #endif
                Text(String(localized: "statusline.note",
                      defaultValue: "Also wraps your statusline command, so the home card can show how much of a session's context is used. Removed together with the hooks."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                
                #if !APPSTORE
                if showDiff {
                    ScrollView {
                        Text(pendingHookJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmInstall() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) {
                            showDiff = false
                            pendingHookJSON = ""
                            pendingUninstall = false
                        }
                            .buttonStyle(.bordered)
                    }
                }
                #endif
            }
            .padding(6)
        }


        #if !APPSTORE
        GroupBox(String(localized: "hooks.gemini.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(geminiHooksInstalled
                     ? String(localized: "hooks.gemini.installed")
                     : "~/.gemini/settings.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerGeminiPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerGeminiPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showGeminiDiff {
                    ScrollView {
                        Text(pendingGeminiJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmGeminiOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showGeminiDiff = false; pendingGeminiJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.antigravity.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(agyHooksInstalled
                     ? String(localized: "hooks.antigravity.installed")
                     : "~/.gemini/config/hooks.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerAgyPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerAgyPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showAgyDiff {
                    ScrollView {
                        Text(pendingAgyJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmAgyOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showAgyDiff = false; pendingAgyJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.codex.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(codexHooksInstalled
                     ? String(localized: "hooks.codex.installed")
                     : "~/.codex/hooks.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerCodexPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerCodexPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showCodexDiff {
                    ScrollView {
                        Text(pendingCodexJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmCodexOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showCodexDiff = false; pendingCodexJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.copilot.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(copilotHooksInstalled
                     ? String(localized: "hooks.copilot.installed")
                     : "~/.copilot/hooks/coucou.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerCopilotPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerCopilotPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showCopilotDiff {
                    ScrollView {
                        Text(pendingCopilotJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmCopilotOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showCopilotDiff = false; pendingCopilotJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.muse.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(museHooksInstalled
                     ? String(localized: "hooks.muse.installed")
                     : "~/.config/muse/settings.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerMusePreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerMusePreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showMuseDiff {
                    ScrollView {
                        Text(pendingMuseJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmMuseOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showMuseDiff = false; pendingMuseJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "plugin.opencode.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(openCodePluginInstalled
                     ? String(localized: "plugin.opencode.installed")
                     : "~/.config/opencode/plugins/coucou.js")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "plugin.install")) { triggerOpenCodePreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerOpenCodePreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showOpenCodeDiff {
                    ScrollView {
                        Text(pendingOpenCodeContent)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmOpenCodeOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showOpenCodeDiff = false; pendingOpenCodeContent = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "plugin.amp.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(ampPluginInstalled
                     ? String(localized: "plugin.amp.installed")
                     : "~/.config/amp/plugins/coucou.ts")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "plugin.install")) { triggerAmpPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerAmpPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showAmpDiff {
                    ScrollView {
                        Text(pendingAmpContent)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmAmpOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showAmpDiff = false; pendingAmpContent = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "plugin.hermes.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(hermesPluginInstalled
                     ? String(localized: "plugin.hermes.installed")
                     : "~/.hermes/plugins/coucou/__init__.py")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    if !hermesPluginInstalled {
                        Button(String(localized: "plugin.install")) { triggerHermesPluginPreview(install: true) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(String(localized: "hooks.uninstall")) { triggerHermesPluginPreview(install: false) }
                            .buttonStyle(.bordered)
                    }
                }
                if showHermesPluginDiff {
                    ScrollView {
                        Text(pendingHermesPluginContent)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmHermesPluginOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showHermesPluginDiff = false; pendingHermesPluginContent = "" }
                            .buttonStyle(.bordered)
                    }
                }

                if hermesPluginInstalled {
                    Divider()
                    Toggle(String(localized: "plugin.hermes.approvals"), isOn: $hermesApprovalsEnabled)
                        .onChange(of: hermesApprovalsEnabled) { _, _ in triggerHermesConfigPreview() }
                        .disabled(!hermesSupportsApprovals)
                    if !hermesSupportsApprovals {
                        Text("Requires a newer version of Hermes — run: hermes update")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(hermesApprovalsEnabled
                             ? String(localized: "plugin.hermes.approvals.enabled")
                             : String(localized: "plugin.hermes.approvals.disabled"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showHermesConfigDiff {
                        ScrollView {
                            Text(pendingHermesConfigContent)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        HStack {
                            Button(String(localized: "hooks.confirm-write")) { confirmHermesConfigOp() }
                                .buttonStyle(.borderedProminent)
                            Button(String(localized: "Cancel")) { showHermesConfigDiff = false; pendingHermesConfigContent = "" }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(6)
        }
        #if !APPSTORE
        .task(id: hermesPluginInstalled) {
            guard hermesPluginInstalled else { hermesSupportsApprovals = false; return }
            let result = await Task.detached(priority: .background) {
                HookServer.hermesSupportsApprovalTransport()
            }.value
            await MainActor.run { hermesSupportsApprovals = result }
        }
        #endif
        #endif
    }

    // MARK: - Actions

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "❌ Startup: \(error.localizedDescription)"
            launchAtStartup = !on
        }
    }

    // MARK: - App Store: hooks via NSOpenPanel + security-scoped bookmark

    #if APPSTORE
    private func pickClaudeFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select your .claude folder (press ⇧⌘. to show hidden files)"
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let realHomePath = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? "/Users/\(NSUserName())"
        panel.directoryURL = URL(fileURLWithPath: realHomePath)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.lastPathComponent == ".claude" else {
            statusMessage = String(localized: "status.select-claude-folder")
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.hooks.title")
        alert.informativeText = String(localized: "alert.hooks.body")
        alert.addButton(withTitle: String(localized: "alert.hooks.button-install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: claudeURL)
            hookNeedsUpdate = false
            statusMessage = String(localized: "status.hooks-installed-claude")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            statusMessage = String(localized: "status.hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func installHooks() {
        do {
            #if !APPSTORE
            pendingHookJSON = try HookServer.shared.previewClaudeHooks(statusLine: true)
            #else
            pendingHookJSON = try HookServer.shared.previewClaudeHooks(statusLine: false)
            #endif
            pendingUninstall = false
            showDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeUninstall()
            pendingUninstall = true
            showDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            if pendingUninstall {
                try HookServer.shared.writeClaudeUninstall()
                #if !APPSTORE
                contextUsageInstalled = false
                #endif
                showDiff = false
                pendingHookJSON = ""
                pendingUninstall = false
                statusMessage = String(localized: "status.hooks-removed")
            } else {
                try HookServer.shared.writeClaudeHooks()
                showDiff = false
                pendingHookJSON = ""
                hookNeedsUpdate = false
                #if !APPSTORE
                contextUsageInstalled = StatusLineReader.isEnabled
                #endif
                // Installing the hooks also wraps the statusline, so the two
                // can come apart: settings.json with no `statusLine.command`
                // has nothing to wrap, and the hooks still went in fine.
                statusMessage = String(
                    localized: contextUsageInstalled
                        ? "status.hooks-installed-settings"
                        : "status.hooks-installed-no-statusline")
            }
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    #if !APPSTORE
    private func triggerGeminiPreview(install: Bool) {
        do {
            geminiPendingInstall = install
            pendingGeminiJSON = try HookServer.shared.previewGeminiHooks(install: install)
            showGeminiDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmGeminiOp() {
        do {
            try HookServer.shared.writeGeminiHooks()
            showGeminiDiff = false
            pendingGeminiJSON = ""
            geminiHooksInstalled = geminiPendingInstall
            statusMessage = geminiPendingInstall
                ? String(localized: "status.gemini-hooks-installed")
                : String(localized: "status.gemini-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAgyPreview(install: Bool) {
        do {
            agyPendingInstall = install
            pendingAgyJSON = try HookServer.shared.previewAgyHooks(install: install)
            showAgyDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmAgyOp() {
        do {
            try HookServer.shared.writeAgyHooks()
            showAgyDiff = false
            pendingAgyJSON = ""
            agyHooksInstalled = agyPendingInstall
            statusMessage = agyPendingInstall
                ? String(localized: "status.agy-hooks-installed")
                : String(localized: "status.agy-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerCodexPreview(install: Bool) {
        do {
            codexPendingInstall = install
            pendingCodexJSON = try HookServer.shared.previewCodexHooks(install: install)
            showCodexDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmCodexOp() {
        do {
            try HookServer.shared.writeCodexHooks()
            showCodexDiff = false
            pendingCodexJSON = ""
            codexHooksInstalled = codexPendingInstall
            statusMessage = codexPendingInstall
                ? String(localized: "status.codex-hooks-installed")
                : String(localized: "status.codex-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerCopilotPreview(install: Bool) {
        do {
            copilotPendingInstall = install
            pendingCopilotJSON = try HookServer.shared.previewCopilotHooks(install: install)
            showCopilotDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmCopilotOp() {
        do {
            try HookServer.shared.writeCopilotHooks()
            showCopilotDiff = false
            pendingCopilotJSON = ""
            copilotHooksInstalled = copilotPendingInstall
            statusMessage = copilotPendingInstall
                ? String(localized: "status.copilot-hooks-installed")
                : String(localized: "status.copilot-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerMusePreview(install: Bool) {
        do {
            musePendingInstall = install
            pendingMuseJSON = try HookServer.shared.previewMuseHooks(install: install)
            showMuseDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmMuseOp() {
        do {
            try HookServer.shared.writeMuseHooks()
            showMuseDiff = false
            pendingMuseJSON = ""
            museHooksInstalled = musePendingInstall
            statusMessage = musePendingInstall
                ? String(localized: "status.muse-hooks-installed")
                : String(localized: "status.muse-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerOpenCodePreview(install: Bool) {
        do {
            openCodePendingInstall = install
            pendingOpenCodeContent = try HookServer.shared.previewOpenCodePlugin(install: install)
            showOpenCodeDiff = true
            statusMessage = String(localized: "plugin.review-content")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmOpenCodeOp() {
        do {
            if openCodePendingInstall {
                try HookServer.shared.writeOpenCodePlugin()
            } else {
                try HookServer.shared.removeOpenCodePlugin()
            }
            showOpenCodeDiff = false
            pendingOpenCodeContent = ""
            openCodePluginInstalled = openCodePendingInstall
            statusMessage = openCodePendingInstall
                ? String(localized: "status.opencode-plugin-installed")
                : String(localized: "status.opencode-plugin-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAmpPreview(install: Bool) {
        do {
            ampPendingInstall = install
            pendingAmpContent = try HookServer.shared.previewAmpPlugin(install: install)
            showAmpDiff = true
            statusMessage = String(localized: "plugin.review-content")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmAmpOp() {
        do {
            if ampPendingInstall {
                try HookServer.shared.writeAmpPlugin()
            } else {
                try HookServer.shared.removeAmpPlugin()
            }
            showAmpDiff = false
            pendingAmpContent = ""
            ampPluginInstalled = ampPendingInstall
            statusMessage = ampPendingInstall
                ? String(localized: "status.amp-plugin-installed")
                : String(localized: "status.amp-plugin-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerHermesPluginPreview(install: Bool) {
        do {
            hermesPluginPendingInstall = install
            pendingHermesPluginContent = try HookServer.shared.previewHermesPlugin(install: install)
            showHermesPluginDiff = true
            statusMessage = String(localized: "plugin.review-content")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmHermesPluginOp() {
        do {
            if hermesPluginPendingInstall {
                try HookServer.shared.writeHermesPlugin()
            } else {
                try HookServer.shared.removeHermesPlugin()
            }
            showHermesPluginDiff = false
            pendingHermesPluginContent = ""
            hermesPluginInstalled = hermesPluginPendingInstall
            statusMessage = hermesPluginPendingInstall
                ? String(localized: "status.hermes-plugin-installed")
                : String(localized: "status.hermes-plugin-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerHermesConfigPreview() {
        do {
            pendingHermesConfigContent = try HookServer.shared.previewHermesConfig(
                enableApprovals: hermesApprovalsEnabled,
                supportsTransport: hermesSupportsApprovals)
            showHermesConfigDiff = true
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmHermesConfigOp() {
        do {
            try HookServer.shared.writeHermesConfig()
            showHermesConfigDiff = false
            pendingHermesConfigContent = ""
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif
}

// MARK: - Sidebar background (NSVisualEffectView .sidebar)

struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Sidebar row (System Settings style icon)

struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let color: String

    var body: some View {
        Label {
            Text(LocalizedStringKey(title))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: color)))
        }
    }
}

// MARK: - Integration filter row (reusable for Vercel / n8n)

struct IntegrationFilterRow: View {
    let label: String
    let items: [String]
    @Binding var filter: Set<String>
    let loading: Bool
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(items.isEmpty ? "Load list" : "Refresh") { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !filter.isEmpty {
                    Button("Clear") { filter = [] }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.secondary)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { filter.isEmpty || filter.contains(item) },
                            set: { on in
                                if on { filter.insert(item) }
                                else  {
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] }
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text(String(format: String(localized: "Watching %lld of %lld"), Int64(filter.count), Int64(items.count)))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcut recorder button

struct ShortcutRecorderButton: View {
    @Binding var flags: UInt
    @Binding var code: UInt16
    @State private var isRecording = false

    var body: some View {
        Button {
            guard !isRecording else { return }
            isRecording = true
            var token: Any?
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !mods.isEmpty else { return event }
                DispatchQueue.main.async {
                    self.flags = mods.rawValue
                    self.code = event.keyCode
                    self.isRecording = false
                    if let t = token { NSEvent.removeMonitor(t) }
                }
                return nil
            }
        } label: {
            Text(isRecording ? "Press keys…" : shortcutLabel)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var shortcutLabel: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyChar(code)
        return s.isEmpty ? "None" : s
    }

    private func keyChar(_ c: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U",
            34:"I", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 49:"Space", 50:"`", 27:"-"
        ]
        return map[c] ?? "·"
    }
}
