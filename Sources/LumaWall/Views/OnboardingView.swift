import SwiftUI

struct OnboardingView: View {
    @Environment(ClipboardManager.self) private var clipboard
    @Environment(ShelfController.self) private var shelf
    @Environment(BarController.self) private var bar
    @Environment(SwitchController.self) private var switches
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onComplete: () -> Void

    @State private var step: Step = .welcome
    @State private var selectedModules: Set<AsterModule> = [.canvas]
    @State private var contentIsVisible = false
    @State private var isFinishing = false

    private enum Step: Int, CaseIterable {
        case welcome
        case mission
        case modules
        case ready

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .mission: "About Aster"
            case .modules: "Choose modules"
            case .ready: "Ready"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "sparkles"
            case .mission: "hand.raised"
            case .modules: "square.grid.2x2"
            case .ready: "checkmark.circle"
            }
        }
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                onboardingHeader

                HStack(spacing: 0) {
                    onboardingSidebar

                    ZStack {
                        switch step {
                        case .welcome:
                            welcomeStep
                                .transition(stepTransition)
                        case .mission:
                            missionStep
                                .transition(stepTransition)
                        case .modules:
                            modulesStep
                                .transition(stepTransition)
                        case .ready:
                            readyStep
                                .transition(stepTransition)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .opacity(isFinishing ? 0 : 1)
            .scaleEffect(isFinishing && !reduceMotion ? 0.99 : 1)
        }
        .background(.clear)
        .allowsHitTesting(!isFinishing)
        .task {
            showContent()
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 850 : 1_750))
            guard !Task.isCancelled, step == .welcome else { return }
            advance(to: .mission)
        }
    }

    private var onboardingHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                Text("Aster")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.asterDeepPurple)
                Text("BETA")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 21)
                    .background(.white.opacity(0.055), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.07), lineWidth: 0.7))
            }

            Spacer()

            HStack(spacing: 7) {
                ForEach([Step.mission, .modules, .ready], id: \.rawValue) { item in
                    Capsule(style: .continuous)
                        .fill(item.rawValue <= step.rawValue ? Color.asterPurple : Color.white.opacity(0.12))
                        .frame(width: item == step ? 26 : 7, height: 7)
                        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: step)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 44)
        .background(.ultraThinMaterial.opacity(0.25))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
        }
    }

    private var onboardingSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GET STARTED")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.15)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)

            VStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 20)
                            .foregroundStyle(item == step ? Color.asterPurple : .secondary)
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        item == step ? Color.white.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }

            Spacer()

            Label("Private and local", systemImage: "lock.shield")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 208)
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.05)).frame(width: 1)
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.asterPurple.opacity(0.08))
                    .frame(width: 92, height: 92)
                    .blur(radius: 18)
                    .scaleEffect(contentIsVisible ? 1.2 : 0.75)

                Image(systemName: "asterisk")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.asterPurple)
                    .rotationEffect(.degrees(contentIsVisible && !reduceMotion ? 180 : 0))
            }

            Text("Welcome to Aster")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.8)

            Text("Private utilities that stay out of your way.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .opacity(contentIsVisible ? 1 : 0)
        .scaleEffect(contentIsVisible ? 1 : 0.94)
        .animation(.easeOut(duration: reduceMotion ? 0.2 : 0.8), value: contentIsVisible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome to Aster")
    }

    private var missionStep: some View {
        VStack(spacing: 34) {
            VStack(spacing: 16) {
                Text("Welcome to a calmer Mac.")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Free. Private. All yours.")
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-0.8)
                    .multilineTextAlignment(.center)

                Text("Aster gives you thoughtful utilities without accounts, ads, analytics,\nor data leaving your Mac.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            HStack(spacing: 12) {
                MissionPill(symbol: "gift.fill", title: "Always free")
                MissionPill(symbol: "hand.raised.fill", title: "Private by design")
                MissionPill(symbol: "slider.horizontal.3", title: "Made to be yours")
            }

            HStack(spacing: 13) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xCBB8FF))
                    .frame(width: 34, height: 34)
                    .background(Color.asterPurple.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aster is currently in beta")
                        .font(.system(size: 13, weight: .semibold))
                    Text("You may find a few rough edges while we improve the experience.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 58)
            .background(Color.asterPurple.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.asterPurple.opacity(0.18), lineWidth: 0.7))

            Button("Choose your modules") {
                advance(to: .modules)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
        }
        .padding(40)
    }

    private var modulesStep: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Text("Make Aster yours")
                    .font(.system(size: 36, weight: .semibold))
                Text("Choose what you want to start with. You can change any module later.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(AsterModule.onboardingCases) { module in
                    ModuleChoiceCard(
                        module: module,
                        isSelected: selectedModules.contains(module)
                    ) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                            if selectedModules.contains(module) {
                                selectedModules.remove(module)
                            } else {
                                selectedModules.insert(module)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 780)

            HStack(spacing: 16) {
                Button("Back") { advance(to: .mission) }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                Button(selectedModules.isEmpty ? "Continue without modules" : "Continue") {
                    advance(to: .ready)
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 28)
    }

    private var readyStep: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(Color.asterPurple.opacity(0.08))
                    .frame(width: 104, height: 104)
                    .blur(radius: 18)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 64, height: 64)
                    .overlay(Circle().stroke(Color.asterPurple.opacity(0.35), lineWidth: 0.8))
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.asterPurple)
            }

            VStack(spacing: 9) {
                Text("You’re ready to explore.")
                    .font(.system(size: 40, weight: .semibold))
                Text(readySummary)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !selectedModules.isEmpty {
                HStack(spacing: 8) {
                    ForEach(selectedModules.sorted(by: { $0.title < $1.title })) { module in
                        Label(module.title, systemImage: module.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(.white.opacity(0.055), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.7))
                    }
                }
            }

            Label("Some modules may ask for macOS permission the first time you use them.", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Back") { advance(to: .modules) }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                Button("Open Aster") { finishOnboarding() }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(48)
    }

    private var readySummary: String {
        if selectedModules.isEmpty {
            return "Aster will stay quiet until you choose a module."
        }
        return "Your setup is ready. Thanks for helping us shape the Aster beta."
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }

    private func showContent() {
        withAnimation { contentIsVisible = true }
    }

    private func advance(to newStep: Step) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.18 : 0.52)) {
            step = newStep
        }
    }

    private func finishOnboarding() {
        guard !isFinishing else { return }

        clipboard.isMonitoring = selectedModules.contains(.clips)
        shelf.isEnabled = selectedModules.contains(.shelf)
        bar.isEnabled = selectedModules.contains(.bar)
        switches.isEnabled = selectedModules.contains(.switchboard)
        AsterModuleSelection.save(selectedModules)

        if reduceMotion {
            onComplete()
            return
        }

        withAnimation(.easeInOut(duration: 0.34)) {
            isFinishing = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            onComplete()
        }
    }
}

private struct MissionPill: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.07), lineWidth: 0.7))
    }
}

private struct ModuleChoiceCard: View {
    let module: AsterModule
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: module.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.asterPurple)
                    .frame(width: 42, height: 42)
                    .background(
                        isSelected ? Color.asterPurple : Color.asterPurple.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(module.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(module.onboardingDescription)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? Color.asterPurple : Color.secondary.opacity(0.55))
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(
                isSelected ? Color.asterPurple.opacity(0.11) : Color.white.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(isSelected ? Color.asterPurple.opacity(0.5) : Color.white.opacity(0.07), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.16)
            RadialGradient(
                colors: [Color.asterPurple.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 720
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .onboardingGlass(cornerRadius: 12, tint: Color.asterPurple.opacity(0.42))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .onboardingGlass(cornerRadius: 12)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func onboardingGlass(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(tint).interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            onboardingLegacyGlass(cornerRadius: cornerRadius)
        }
        #else
        onboardingLegacyGlass(cornerRadius: cornerRadius)
        #endif
    }

    func onboardingLegacyGlass(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

private extension AsterModule {
    static let onboardingCases = onboardingOrder

    var onboardingDescription: String {
        switch self {
        case .canvas:
            "Set beautiful still and motion wallpapers."
        case .clips:
            "Keep a searchable clipboard history on this Mac."
        case .shelf:
            "Open useful widgets from a home around the notch."
        case .bar:
            "Tidy third-party menu bar icons behind Aster."
        case .switchboard:
            "Put everyday Mac controls in one quiet place."
        case .home, .ask:
            subtitle
        }
    }

}
