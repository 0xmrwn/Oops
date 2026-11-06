import OopsCore
import SwiftUI

/// The provider step unfolds into two short pages, keeping its character fixed. Its forward action
/// and its way back sit in the step's footer (`APIProviderSetupPrimary`), sharing the fields' focus.
struct APIProviderSetupView: View {
    @Bindable var setup: APIProviderSetup
    let focus: FocusState<Field?>.Binding
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    private var accessibleGlass: Bool { reduceTransparency || contrast == .increased || DebugFlags.onboardingAccessibleGlass }
    enum Field: Hashable { case endpoint, key, model }

    private var proof: ProviderStep.Proof {
        switch setup.phase {
        case .proving: .running
        case .passed(let answer, let seconds): .passed(answer, seconds: seconds)
        default: .idle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 14) {
                    if setup.connected { modelFields } else { connectionFields }
                }
                .frame(height: 112)
                .padding(16)
                .glassEffect(accessibleGlass ? .regular : .clear, in: .rect(cornerRadius: 20))
            }
            .disabled(setup.busy)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: setup.connected)
            feedback.frame(height: 56)
        }
        .frame(width: 440)
        .onAppear { DispatchQueue.main.async { focusFirst() } }
        .onDisappear { setup.enteringKey = false }
        .onChange(of: setup.preset) { focusFirst() }
        .onChange(of: setup.connected) { focusFirst() }
        .onChange(of: focus.wrappedValue) { _, field in setup.enteringKey = field == .key }
        .onChange(of: setup.error) { _, error in
            if let error {
                AccessibilityNotification.Announcement(error).post()
                if !setup.connected { focus.wrappedValue = error.localizedCaseInsensitiveContains("key") ? .key : .endpoint }
                else if !setup.passed { Sounds.play(.failure, after: 0) }
            }
        }
        .onChange(of: setup.phase) { _, phase in
            if case .passed = phase { focus.wrappedValue = nil; Sounds.play(.success, after: 0) }
        }
    }

    private var connectionFields: some View {
        Group {
            field("Provider") {
                presetMenu
            }
            field("Endpoint") {
                TextField("https://api.example.com/v1", text: Binding(get: { setup.endpoint }, set: setup.changeEndpoint))
                    .focused(focus, equals: .endpoint).onSubmit(connect)
                    .accessibilityLabel("Endpoint")
            }
            field("API key") {
                SecureField(setup.keyOptional ? "Optional" : "Required", text: Binding(get: { setup.key }, set: setup.changeKey))
                    .focused(focus, equals: .key).onSubmit(connect)
                    .accessibilityLabel(setup.keyOptional ? "API key, optional" : "API key, required")
                    .help("Saved in Keychain only when you continue")
            }
        }
        .textFieldStyle(.roundedBorder).controlSize(.large)
    }

    @ViewBuilder
    private var modelFields: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 22)
            Text(setup.name).font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Edit") { setup.edit() }.buttonStyle(.glass)
                .accessibilityLabel("Edit API connection")
        }
        Text(setup.address).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(.white.opacity(0.85)).help(setup.address)
        Divider().overlay(.white.opacity(0.15))
        field("Model") {
            Picker("Model", selection: Binding(get: { setup.model }, set: { setup.chooseModel($0) })) {
                ForEach(setup.models) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.large)
            .focused(focus, equals: .model)
        }
    }

    private var provider: Provider {
        Provider(id: "onboarding-api", kind: .api(preset: setup.preset?.id), name: setup.name, baseURL: setup.address)
    }

    private var presetMenu: some View {
        Menu {
            Button { setup.choose(nil) } label: { Label { Text("Custom API") } icon: { MenuIcon.symbol("server.rack") } }
            Divider()
            ForEach(ProviderPreset.all) { preset in
                Button { setup.choose(preset) } label: {
                    Label { Text(preset.name) } icon: { MenuIcon.image(preset.logoAsset, template: true) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                ProviderMark(provider: provider, size: 20)
                Text(setup.preset?.name ?? "Custom API")
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.primary.opacity(0.08), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Provider, \(setup.preset?.name ?? "Custom API")")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 14, weight: .medium)).frame(width: 70, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let error = setup.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 13, weight: .medium)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Setup failed. \(error)")
        } else if setup.phase == .discovering {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding models…").font(.system(size: 13, weight: .medium))
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                if setup.phase == .proving { ProgressView().controlSize(.small).accessibilityLabel("Testing model") }
                ProofChip(proof: proof)
            }
        }
    }

    private func connect() { focus.wrappedValue = nil; setup.connect() }
    private func focusFirst() { focus.wrappedValue = setup.connected ? .model : setup.preset == nil || setup.keyOptional ? .endpoint : .key }
}

/// The API pages' forward action, in the step's primary slot: Connect, Test model, then Continue.
struct APIProviderSetupPrimary: View {
    let setup: APIProviderSetup
    let focus: FocusState<APIProviderSetupView.Field?>.Binding
    let next: () -> Void

    var body: some View {
        if setup.busy {
            OnboardingNextButton(title: setup.phase == .discovering ? "Connecting…" : "Testing…", symbol: nil) {}.disabled(true).opacity(0.65)
        } else if setup.passed {
            OnboardingNextButton(title: "Continue", action: next)
        } else if setup.connected {
            OnboardingNextButton(title: setup.error == nil ? "Test model" : "Try again") { focus.wrappedValue = nil; setup.prove() }
                .disabled(!setup.canProve)
        } else {
            OnboardingNextButton(title: setup.error == nil ? "Connect" : "Try again") { focus.wrappedValue = nil; setup.connect() }
                .disabled(!setup.canConnect).opacity(setup.canConnect ? 1 : 0.45)
        }
    }
}
