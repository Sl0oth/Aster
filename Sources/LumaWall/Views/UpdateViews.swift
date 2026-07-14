import SwiftUI

struct UpdateDetailsView: View {
    @Environment(UpdateManager.self) private var updates
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.asterPurple)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 4) {
                    Text(updates.availableRelease.map { "Aster \($0.version) is available" } ?? "Aster Update")
                        .font(.system(size: 23, weight: .semibold))
                    Text(updates.availableRelease?.headline ?? updates.statusMessage)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let release = updates.availableRelease {
                Text(release.summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !release.features.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("WHAT’S NEW")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(.tertiary)
                        ForEach(release.features) { feature in
                            ReleaseFeatureRow(feature: feature)
                        }
                    }
                }
            }

            Divider().overlay(.white.opacity(0.06))

            HStack {
                Label(updates.statusMessage, systemImage: updateStatusSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Later") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(updateActionTitle) {
                    if updates.state == .downloaded {
                        updates.openDownloadedUpdate()
                    } else {
                        updates.downloadAvailableUpdate()
                    }
                }
                .buttonStyle(UpdateActionButtonStyle())
                .disabled(updates.availableRelease == nil || updates.isBusy)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(.ultraThinMaterial)
    }

    private var updateActionTitle: String {
        switch updates.state {
        case .downloading: "Downloading…"
        case .downloaded: "Open Download"
        default: "Update Aster"
        }
    }

    private var updateStatusSymbol: String {
        switch updates.state {
        case .failed: "exclamationmark.triangle.fill"
        case .downloaded: "checkmark.circle.fill"
        default: "lock.shield.fill"
        }
    }
}

struct WhatsNewView: View {
    let release: AsterBundledReleaseNotes
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.asterPurple)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What’s new in Aster")
                            .font(.system(size: 24, weight: .semibold))
                        Text("Version \(release.version) · \(release.headline)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("BETA")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(.white.opacity(0.045), in: Capsule())
                }

                Text(release.summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)

                VStack(spacing: 9) {
                    ForEach(release.features) { feature in
                        ReleaseFeatureRow(feature: feature)
                    }
                }

                HStack {
                    Text("Aster is still in beta. Thanks for helping make it better.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Continue", action: dismiss)
                        .buttonStyle(UpdateActionButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 590)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.42), radius: 36, y: 14)
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.975)
        }
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.3)) {
                isVisible = true
            }
        }
    }
}

private struct ReleaseFeatureRow: View {
    let feature: AsterReleaseFeature

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.asterPurple)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(feature.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.05), lineWidth: 0.7))
    }
}

private struct UpdateActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(.white.opacity(configuration.isPressed ? 0.13 : 0.085), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1), lineWidth: 0.7))
    }
}
