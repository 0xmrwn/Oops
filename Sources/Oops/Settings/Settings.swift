import AppKit
import SwiftUI
import OopsCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", providers = "Providers", about = "About"
    var id: Self { self }
    static var launchPreview: Self {
        switch DebugFlags.settingsTab {
        case "provider", "providers": .providers
        case "try", "customize", "advanced": .general
        case "about", "stats", "changelog", "debug", "developer", "diagnostics": .about
        default: .general
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "sparkles"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    /// The Try page's draft and status; the correction runs through AppDelegate's real pipeline.
    let testEditor: TestEditorModel
    let preview: () -> Void
    let previewPlacement: @MainActor () async -> String
    /// Every page shares one window height, so switching never resizes the window.
    static let height: CGFloat = 744
    /// Drops keyboard focus to the window, so no ring stays on a control of a page being hidden.
    var clearFocus: () -> Void = {}
    /// Launch-only screenshot aid: `-SettingsPreviewTab provider` (never persisted).
    @State private var page = SettingsPage.launchPreview
    /// The page fading out: it stays enabled until its fade ends, so its controls never dim.
    @State private var leaving: SettingsPage?
    /// The page whose controls are live: the chosen one, set a frame before the switch animates.
    @State private var enabled = SettingsPage.launchPreview
    /// General's drilled-in page. Launch-only aid: `-SettingsPreviewTab try` or `customize`.
    @State private var generalDetail = GeneralDetail.launchPreview
    /// About's drilled-in page. Launch-only aid: `-SettingsPreviewTab debug` or `changelog`.
    @State private var aboutDetail = AboutDetail.launchPreview
    @State private var accessibilityEnabled = AccessibilityPermission.granted
    /// Written on every pointer move and page change; only the eyes read it, so nothing else
    /// re-evaluates.
    @State private var spare = SpareSpaceModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    @Environment(\.settingsStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
                // Fixed app chrome: the brand, then the primary navigation. Only the page below
                // them changes.
                brand
                    .padding(.horizontal, 28)
                    .padding(.top, 54)
                SettingsTabBar(selection: pageSelection)
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Every page is built once and kept: a switch only animates views that
                            // exist. Rebuilding the destination page on each click stalled its
                            // first frame by 70–90 ms.
                            // Inside the scroll view, so glass panes clip with the scrolled content.
                            // Each page has its own container: one shared container renders its
                            // children's glass and content itself and ignores a hidden page's
                            // opacity, so every page would show through.
                            GlassEffectContainer(spacing: 8) {
                                ZStack(alignment: .topLeading) {
                                    ForEach(SettingsPage.allCases) { candidate in
                                        GlassEffectContainer(spacing: 8) { pageContent(candidate) }
                                            .modifier(PageSwap(position: position(of: candidate), enabled: candidate == enabled || candidate == leaving,
                                                               reduceMotion: reduceMotion))
                                    }
                                }
                            }
                        }
                        .id("top")
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { spare.content = $0 }
                    }
                    .scrollIndicators(.automatic)
                    .scrollBounceBehavior(.basedOnSize)
                    // Content leaving under the tab bar fades out instead of a hard cut. The fade fits in
                    // the page's top padding, so nothing at rest is touched. (The system scroll edge
                    // effect only draws under an overlapping bar, which the tab bar is not.)
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                            Color.black
                        }
                    }
                    // A page taller than the window makes the scroll view a focus stop; AppKit
                    // then hands it focus after popovers close, with a ring around nothing.
                    .focusEffectDisabled()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { spare.viewport = $0 }
                    // Whatever height the page leaves below it goes to the eyes.
                    .overlay(alignment: .bottom) { SpareSpace(model: spare, suppressed: page == .general && generalDetail == .tryPage) }
                    // The maker's note: About's footer, under the eyes.
                    .overlay(alignment: .bottom) {
                        let shown = page == .about && aboutDetail == nil
                        Credit().padding(.bottom, 18)
                            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
                            .animation(SettingsMotion.page(reduceMotion), value: shown)
                    }
                    .onChange(of: page) { _, _ in scroller.scrollTo("top", anchor: .top) }
                }
        }
        .frame(width: 620)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { if style.opaque { Color(nsColor: .windowBackgroundColor) } }
        // Measure and lay out the whole window, title bar included, so the fit is exact.
        .ignoresSafeArea()
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let location) = phase { spare.pointer = location } else { spare.pointer = nil }
        }
        // Launch-only screenshot aid: `-SettingsPreviewPointer 80,600` puts the pointer there (window
        // points from the top left) for the eyes, without moving the real one.
        .onAppear {
            let parts = DebugFlags.pointer?.split(separator: ",").compactMap { Double($0) }
            if let parts, parts.count == 2 { spare.pointer = CGPoint(x: parts[0], y: parts[1]) }
        }
        .onChange(of: page) { _, page in if page == .providers { providerAppeared() } }
        // The menu, `--fixture` and the perf harness open the Try page.
        .onReceive(testEditor.$requested) { requested in
            guard requested else { return }
            testEditor.requested = false
            if page != .general { pageSelection.wrappedValue = .general }
            withAnimation(SettingsMotion.drill(reduceMotion)) { generalDetail = .tryPage }
        }
        .onChange(of: page == .general && generalDetail == .tryPage, initial: true) { _, shown in testEditor.presented = shown }
        // About's footer sits under the eyes.
        .onChange(of: page == .about && aboutDetail == nil, initial: true) { _, footer in spare.reserved = footer ? 44 : 0 }
        // Initial too: the capsule's Settings remedy can ask before this view exists.
        .onChange(of: preferences.providers.wantsProvidersPage, initial: true) { _, wanted in
            guard wanted else { return }
            preferences.providers.wantsProvidersPage = false
            pageSelection.wrappedValue = .providers
        }
        // Debug-only (`SettingsPreviewCycle`, or the perf harness): steps through the tabs, for
        // recording and profiling the switch.
        .task {
            guard DebugFlags.cycleTabs || DebugFlags.perfHarness == "settings" else { return }
            let order = SettingsPage.allCases
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                #if DEBUG
                FramePacer.current?.markChange()
                #endif
                pageSelection.wrappedValue = order[((order.firstIndex(of: page) ?? 0) + 1) % order.count]
            }
        }
        .sheet(isPresented: $preferences.showWelcome) {
            ChatGPTWelcomeSheet { preferences.showWelcome = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermission() }
        // Changed in System Settings while this window stays open; macOS posts before the change applies.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermission()
            if page == .providers { providerAppeared() }
        }
    }

    /// Where a page sits relative to the one shown: -1 to its left, 0 shown, 1 to its right.
    private func position(of candidate: SettingsPage) -> Int {
        let order = SettingsPage.allCases
        return (order.firstIndex(of: candidate) ?? 0).signum(relativeTo: order.firstIndex(of: page) ?? 0)
    }

    /// Pages slide in from their side of the tab order (see `PageSwap`).
    private var pageSelection: Binding<SettingsPage> {
        Binding(get: { page }, set: { destination in
            // The chosen tab again goes back to its list, like a tab bar on iOS.
            guard destination != page else {
                withAnimation(SettingsMotion.drill(reduceMotion)) {
                    if page == .general { generalDetail = nil }
                    if page == .providers { preferences.providers.closeDetail() }
                    if page == .about { aboutDetail = nil }
                }
                return
            }
            clearFocus()
            NotificationCenter.default.post(name: .settingsPageWillChange, object: nil)
            let previous = page
            // Enabling a page re-styles every control on it. Do it first, while the page is
            // still invisible and nothing moves, then animate from the next frame; the leaving
            // page is disabled once its fade is over, when nothing moves either.
            leaving = previous
            enabled = destination
            DispatchQueue.main.async {
                withAnimation(SettingsMotion.page(reduceMotion)) { page = destination } completion: {
                    if leaving == previous { leaving = nil }
                }
            }
        })
    }

    private func providerAppeared() {
        preferences.refreshChatGPT(loadCatalog: true)
        preferences.providers.refresh()
    }

    private var brand: some View {
        HStack(spacing: 14) {
            if let icon = AppIcon.image(dark: colorScheme == .dark) {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 56, height: 56).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Oops").font(.system(size: 26, weight: .semibold)).accessibilityAddTraits(.isHeader)
                // The running tally, once there is one; it opens the charts.
                let fixed = Stats.shared.mistakesFixed
                if fixed > 0 {
                    Button {
                        // Choosing About again would pop its page, so only switch from another tab.
                        if page != .about { pageSelection.wrappedValue = .about }
                        withAnimation(SettingsMotion.drill(reduceMotion)) { aboutDetail = .stats }
                    } label: {
                        Text("\(fixed.formatted()) mistakes fixed").font(.callout).secondaryText().monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .focusable(false)
                    .help("Show stats")
                }
            }
            Spacer(minLength: 0)
            HeaderEyes(model: spare, suppressed: page == .general && generalDetail == .tryPage)
        }
    }

    /// Each page is its own view with only the inputs it reads, so a switch (which changes this
    /// view's state) re-evaluates none of them: SwiftUI skips a page whose inputs are unchanged.
    @ViewBuilder private func pageContent(_ page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralPage(hasAccessibility: hasAccessibility, store: preferences.providers, testEditor: testEditor, detail: $generalDetail)
        case .providers: ProvidersPage(store: preferences.providers, preferences: preferences)
        case .about:
            AboutPage(detail: $aboutDetail, hasAccessibility: hasAccessibility, preferences: preferences, preview: preview, previewPlacement: previewPlacement)
        }
    }

    // This launch-only preview never grants permission or changes the system setting.
    private var hasAccessibility: Bool {
        accessibilityEnabled && !DebugFlags.missingAccessibility
    }

    private func refreshPermission() { accessibilityEnabled = AccessibilityPermission.granted }
}

extension Notification.Name {
    /// Popovers on a page close when it hides: pages stay alive, and so would their popovers.
    static let settingsPageWillChange = Notification.Name("oops.settingsPageWillChange")
}

/// The tab bar: a capsule track spanning the content, with one Liquid Glass pill that slides to
/// the chosen tab on the page spring. The pill is a single view that only moves: inserting a new
/// pill in each tab on every click cost a glass layer's creation and teardown per switch.
/// ⌘1–⌘3 switch tabs; tabs are not keyboard focus stops, so no focus ring lands on them when
/// the window opens.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsPage
    @Environment(\.colorScheme) private var colorScheme
    private static let inset: CGFloat = 4, gap: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(SettingsPage.allCases.enumerated()), id: \.element) { index, page in
                let selected = page == selection
                Button { selection = page } label: {
                    HStack(spacing: 7) {
                        Label(page.rawValue, systemImage: page.symbol)
                        // A waiting update, said in words where the eye lands after the tab's name.
                        if page == .about, Updates.shared.pending != nil {
                            Text("Update")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: .capsule)
                                .accessibilityLabel("Update available")
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(selected ? 1 : 0.72))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(page.rawValue) · ⌘\(index + 1)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .background(alignment: .leading) { pill }
        .background {
            // The track: a faint plate with a hairline, so the glass pill is the only glass here. In
            // light the glass's edge stands in for the hairline, which a white backdrop washes out.
            Capsule().fill(.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                .overlay { if colorScheme == .dark { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) } }
                .glassEdge(Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }

    private var pill: some View {
        GeometryReader { proxy in
            let count = CGFloat(SettingsPage.allCases.count)
            let width = (proxy.size.width - 2 * Self.inset - (count - 1) * Self.gap) / count
            let index = CGFloat(SettingsPage.allCases.firstIndex(of: selection) ?? 0)
            Capsule().fill(.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEdge(Capsule(), outside: true)
                .frame(width: width, height: proxy.size.height - 2 * Self.inset)
                .offset(x: Self.inset + index * (width + Self.gap), y: Self.inset)
        }
    }
}
