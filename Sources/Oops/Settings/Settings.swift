import AppKit
import SwiftUI
import OopsCore

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
    /// The tabs this build shows; fixed for the life of the process.
    private let tabs = SettingsTab.shown
    /// Launch-only screenshot aid: `-SettingsPreviewTab provider` (never persisted).
    @State private var page = SettingsTab.launch(DebugFlags.settingsTab, visible: SettingsTab.shown)
    /// The page fading out: it stays enabled until its fade ends, so its controls never dim.
    @State private var leaving: SettingsTab?
    /// The page whose controls are live: the chosen one, set a frame before the switch animates.
    @State private var enabled = SettingsTab.launch(DebugFlags.settingsTab, visible: SettingsTab.shown)
    /// General's drilled-in page. Launch-only aid: `-SettingsPreviewTab stats`, `changelog` or `debug`.
    @State private var generalDetail = GeneralDetail.launchPreview
    /// Fix's drilled-in page. Launch-only aid: `-SettingsPreviewTab try`, `customize` or `apps`.
    @State private var fixDetail = FixDetail.launchPreview
    /// Bumped to bring the page back to its top without a page change (the update pill on General).
    @State private var toTop = 0
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
                SettingsTabBar(tabs: tabs, selection: pageSelection)
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
                                    ForEach(tabs) { candidate in
                                        GlassEffectContainer(spacing: 8) { pageContent(candidate) }
                                            .modifier(PageSwap(position: SettingsTab.side(of: candidate, shown: page, in: tabs),
                                                               enabled: candidate == enabled || candidate == leaving,
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
                    .overlay(alignment: .bottom) { SpareSpace(model: spare, suppressed: tryShown) }
                    .onChange(of: page) { _, _ in scroller.scrollTo("top", anchor: .top) }
                    .onChange(of: toTop) { _, _ in withAnimation(SettingsMotion.page(reduceMotion)) { scroller.scrollTo("top", anchor: .top) } }
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
            if page != .fix { pageSelection.wrappedValue = .fix }
            withAnimation(SettingsMotion.drill(reduceMotion)) { fixDetail = .tryPage }
        }
        .onChange(of: tryShown, initial: true) { _, shown in testEditor.presented = shown }
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                #if DEBUG
                FramePacer.current?.markChange()
                #endif
                pageSelection.wrappedValue = tabs[((tabs.firstIndex(of: page) ?? 0) + 1) % tabs.count]
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

    /// Try has eyes of its own (its status line), so the window's stay away.
    private var tryShown: Bool { page == .fix && fixDetail == .tryPage }

    /// Pages slide in from their side of the tab order (see `PageSwap`).
    private var pageSelection: Binding<SettingsTab> {
        Binding(get: { page }, set: { destination in
            // The chosen tab again goes back to its list, like a tab bar on iOS.
            guard destination != page else {
                withAnimation(SettingsMotion.drill(reduceMotion)) {
                    if page == .general { generalDetail = nil }
                    if page == .fix { fixDetail = nil }
                    if page == .providers { preferences.providers.closeDetail() }
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

    /// An overview row's jump: the tab's own page, not whatever was drilled into there before.
    private func open(_ tab: SettingsTab) {
        if tab == .fix { fixDetail = nil }
        pageSelection.wrappedValue = tab
    }

    /// The update pill: General's top, where the update's card is.
    private func showUpdate() {
        if page == .general {
            withAnimation(SettingsMotion.drill(reduceMotion)) { generalDetail = nil }
            toTop += 1
        } else {
            generalDetail = nil
            pageSelection.wrappedValue = .general
        }
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
                        // Choosing General again would pop its page, so only switch from another tab.
                        if page != .general { pageSelection.wrappedValue = .general }
                        withAnimation(SettingsMotion.drill(reduceMotion)) { generalDetail = .stats }
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
            // A waiting update takes the eyes' place, on every page.
            ZStack(alignment: .trailing) {
                if let release = Updates.shared.pending {
                    UpdatePill(release: release, open: showUpdate)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                } else {
                    HeaderEyes(model: spare, suppressed: tryShown)
                }
            }
            .animation(SettingsMotion.swap(reduceMotion), value: Updates.shared.pending)
        }
    }

    /// Each page is its own view with only the inputs it reads, so a switch (which changes this
    /// view's state) re-evaluates none of them: SwiftUI skips a page whose inputs are unchanged.
    @ViewBuilder private func pageContent(_ page: SettingsTab) -> some View {
        switch page {
        case .general:
            GeneralPage(hasAccessibility: hasAccessibility, tabs: tabs, store: preferences.providers, preferences: preferences,
                        detail: $generalDetail, open: open, preview: preview, previewPlacement: previewPlacement)
        case .fix: FixPage(store: preferences.providers, testEditor: testEditor, detail: $fixDetail)
        case .dictate: DictatePage(store: preferences.providers)
        case .actions: ActionsPage()
        case .providers: ProvidersPage(store: preferences.providers, preferences: preferences)
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
    /// General's Turn on: the tab named by the object starts recording its feature's shortcut.
    static let settingsRecordShortcut = Notification.Name("oops.settingsRecordShortcut")
}
