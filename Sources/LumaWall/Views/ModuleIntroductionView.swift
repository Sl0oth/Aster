import SwiftUI

struct ModuleIntroductionView: View {
    let module: AsterModule
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()

            RadialGradient(
                colors: [module.accent.opacity(0.14), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 540
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Rectangle()
                    .fill(module.accent.opacity(0.72))
                    .frame(height: 3)

                VStack(alignment: .leading, spacing: 22) {
                    header
                    gettingStarted

                    HStack(alignment: .top, spacing: 12) {
                        shortcuts
                        privacyPanel
                    }

                    HStack(spacing: 12) {
                        Text("You’ll only see this once for \(module.title).")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Start using \(module.title)", action: dismiss)
                            .buttonStyle(ModuleIntroductionButtonStyle(accent: module.accent))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(26)
            }
            .frame(width: 740)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.42), radius: 38, y: 16)
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.965)
            .offset(y: isVisible || reduceMotion ? 0 : 10)
        }
        .onAppear {
            withAnimation(.spring(response: reduceMotion ? 0.12 : 0.42, dampingFraction: 0.86)) {
                isVisible = true
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(module.accent.opacity(0.14))
                    .frame(width: 66, height: 66)
                    .blur(radius: 14)
                Image(systemName: module.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(module.accent)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(module.accent.opacity(0.24), lineWidth: 0.8)
                    }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome to \(module.title)")
                    .font(.system(size: 27, weight: .semibold))
                Text(module.introductionDescription)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            Text("QUICK TOUR")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.15)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.045), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.07), lineWidth: 0.7))
        }
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("HOW IT WORKS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.15)
                .foregroundStyle(.tertiary)

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(module.introductionSteps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("0\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(module.accent)

                        Text(step)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(index == 0 ? module.accent.opacity(0.24) : .white.opacity(0.06), lineWidth: 0.7)
                    }
                }
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("SHORTCUTS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.15)
                .foregroundStyle(.tertiary)

            if module.introductionShortcuts.isEmpty {
                Text("No shortcut needed to get started.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    ForEach(module.introductionShortcuts) { shortcut in
                        HStack(spacing: 8) {
                            Text(shortcut.keys)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.08), lineWidth: 0.7))
                            Text(shortcut.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            Text("Shortcuts work while Aster is open. Global shortcuts work from any app.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.055), lineWidth: 0.7))
    }

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(module.accent)
                .frame(width: 34, height: 34)
                .background(module.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("PRIVATE BY DESIGN")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.05)
                .foregroundStyle(.tertiary)

            Text(module.introductionPrivacyNote)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 238)
        .frame(minHeight: 126, alignment: .topLeading)
        .background(module.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(module.accent.opacity(0.16), lineWidth: 0.7))
    }
}

private struct ModuleIntroductionButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .moduleIntroductionGlass(cornerRadius: 12, tint: accent.opacity(0.42))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func moduleIntroductionGlass(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(tint).interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            moduleIntroductionLegacyGlass(cornerRadius: cornerRadius)
        }
        #else
        moduleIntroductionLegacyGlass(cornerRadius: cornerRadius)
        #endif
    }

    func moduleIntroductionLegacyGlass(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

private struct ModuleIntroductionShortcut: Identifiable {
    let keys: String
    let label: String

    var id: String { keys + label }
}

private extension AsterModule {
    var introductionDescription: String {
        switch self {
        case .canvas: "Create a personal desktop with still images, GIFs, and looping video."
        case .clips: "A searchable clipboard history that stays private and close at hand."
        case .shelf: "A quiet home around the notch for widgets, tools, and things you need next."
        case .bar: "Bring order to a crowded menu bar without replacing the apps already there."
        case .switchboard: "Common Mac controls gathered into one simple, reversible control panel."
        case .home: "Your private utility layer."
        case .ask: "Optional AI actions that stay under your control."
        }
    }

    var introductionSteps: [String] {
        switch self {
        case .canvas:
            ["Import an image, GIF, or video.", "Choose Desktop, Lock Screen, or Screen Saver.", "Preview the result, then apply it."]
        case .clips:
            ["Enable clipboard monitoring.", "Copy text, links, colors, or images normally.", "Open Clips to search, reuse, or pin an item."]
        case .shelf:
            ["Enable Shelf from this page.", "Move the pointer to the notch to open it.", "Choose widgets and adjust its size to fit you."]
        case .bar:
            ["Enable Bar to add its two menu bar controls.", "Command-drag the divider beside utility icons.", "Click Aster in the menu bar to hide or reveal them."]
        case .switchboard:
            ["Choose the control you want to change.", "Use its toggle, slider, or action button.", "Reverse a change anytime from the same control."]
        case .home, .ask:
            ["Review the available controls.", "Choose the options you want.", "Change them again whenever you like."]
        }
    }

    var introductionShortcuts: [ModuleIntroductionShortcut] {
        switch self {
        case .canvas:
            [ModuleIntroductionShortcut(keys: "⌘O", label: "Import media"), ModuleIntroductionShortcut(keys: "⌘2", label: "Open Canvas")]
        case .clips:
            [ModuleIntroductionShortcut(keys: "⇧⌘V", label: "Open globally"), ModuleIntroductionShortcut(keys: "⌘3", label: "Open Clips")]
        case .shelf:
            [ModuleIntroductionShortcut(keys: "⌘4", label: "Open Shelf settings")]
        case .bar:
            [ModuleIntroductionShortcut(keys: "⌘5", label: "Open Bar setup")]
        case .switchboard:
            [ModuleIntroductionShortcut(keys: "⌘6", label: "Open Switch")]
        case .home, .ask:
            []
        }
    }

    var introductionPrivacyNote: String {
        switch self {
        case .canvas: "Your wallpaper library stays on this Mac."
        case .clips: "History stays local, and supported password managers are excluded."
        case .shelf: "Widgets stay local unless you explicitly enable a network feature."
        case .bar: "Bar organizes native menu items without recording their contents."
        case .switchboard: "Switch sends no settings or usage data anywhere."
        case .home, .ask: "Your preferences stay on this Mac."
        }
    }
}
