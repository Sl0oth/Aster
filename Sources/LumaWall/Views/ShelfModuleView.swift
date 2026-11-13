import AppKit
import SwiftUI

struct ShelfModuleView: View {
    @Environment(ShelfController.self) private var shelf
    @State private var displays = AsterDisplay.connected

    var body: some View {
        @Bindable var shelf = shelf
        VStack(spacing: 0) {
            ModuleHeader(module: .shelf) {
                Toggle("Enable Shelf", isOn: $shelf.isEnabled).toggleStyle(.switch)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introduction
                    behaviorSection
                    EditorSection(title: "Appearance", subtitle: "Keep only the details you want to see.") {
                        Toggle("Outer outline", isOn: $shelf.showsOutline)
                        Toggle("Date in the header", isOn: $shelf.showsHeaderDate)
                        Toggle("Time in the header", isOn: $shelf.showsHeaderTime)
                    }
                    widgetsSection
                    if shelf.showsTimer || shelf.showsAlarm { timersSection }
                    if shelf.showsShortcuts { shortcutsSection }
                    if shelf.showsWeather { weatherSection }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(22)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            displays = AsterDisplay.connected
        }
    }

    private var introduction: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .frame(width: 76, height: 50)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 0.7)
                    }
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                    .fill(.black)
                    .frame(width: 35, height: 13)
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.asterAccent)
                    .offset(y: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Move your pointer behind the notch")
                    .font(.system(size: 15, weight: .semibold))
                Text("Push your pointer into the top-center edge of the display, directly behind the notch, and Shelf will open.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(shelf.isExpanded ? "Close Shelf" : "Open Shelf now") {
                shelf.toggleExpansion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(shelf.isEnabled ? Color.asterAccentLight : Color.secondary)
            .disabled(!shelf.isEnabled)
        }
        .padding(16)
        .background(.thinMaterial.opacity(0.34), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.7)
        }
    }

    private var behaviorSection: some View {
        @Bindable var shelf = shelf
        return EditorSection(title: "Behavior", subtitle: "Shelf lives behind the notch and stays out of the Dock.") {
            Toggle("Open when the pointer reaches the notch", isOn: $shelf.opensOnHover)
            ShelfSettingRow(title: "Open after") {
                Picker("Open after", selection: $shelf.hoverDelay) {
                    ForEach(ShelfController.hoverDelayChoices, id: \.self) { delay in
                        Text(hoverDelayLabel(delay)).tag(delay)
                    }
                }
            }
            .disabled(!shelf.opensOnHover)
            .opacity(shelf.opensOnHover ? 1 : 0.5)
            ShelfSettingRow(title: "Show on") {
                Picker("Show on", selection: $shelf.displayKey) {
                    Text("Automatic").tag(String?.none)
                    ForEach(displays) { display in
                        Text(display.name).tag(String?.some(display.key))
                    }
                    if let key = shelf.displayKey, !displays.contains(where: { $0.key == key }) {
                        Text("Disconnected display").tag(String?.some(key))
                    }
                }
            }
            Text("Automatic uses the display with a notch, or your main display.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Width")
                    Spacer()
                    Text("\(Int(shelf.shelfWidth)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $shelf.shelfWidth, in: 360...620) { Text("Width") }
                    .labelsHidden()
            }
        }
    }

    private var widgetsSection: some View {
        EditorSection(
            title: "Widgets",
            subtitle: "Turn on what you want and use the arrows to set the order. Wide widgets take a full row; the rest sit side by side."
        ) {
            VStack(spacing: 0) {
                ForEach(shelf.widgetOrder) { widget in
                    HStack(spacing: 10) {
                        Image(systemName: widget.symbol)
                            .foregroundStyle(shelf.isShown(widget) ? Color.asterAccentLight : .secondary)
                            .frame(width: 22)
                        Text(widget.title)
                        Text(widget.isWide ? "Wide" : "Compact")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button { shelf.moveWidget(widget, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(!shelf.canMoveWidget(widget, by: -1))
                        .help("Move \(widget.title) up")
                        Button { shelf.moveWidget(widget, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(!shelf.canMoveWidget(widget, by: 1))
                        .help("Move \(widget.title) down")
                        Toggle(widget.title, isOn: Binding(
                            get: { shelf.isShown(widget) },
                            set: { shelf.setShown($0, for: widget) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.white.opacity(0.045)).frame(height: 1)
                    }
                }
            }
            HStack {
                Text("Reminders asks before using the Reminders app. Weather only sends the city you enter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset Order") { shelf.resetWidgetOrder() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(shelf.widgetOrder == ShelfWidget.allCases)
            }
        }
    }

    private var timersSection: some View {
        @Bindable var shelf = shelf
        return EditorSection(title: "Timers and alarms", subtitle: "Choose the Quick Timer buttons and how Shelf tells you time is up.") {
            HStack(spacing: 14) {
                Text("Timer buttons")
                Spacer()
                ForEach(Array(shelf.timerPresets.enumerated()), id: \.offset) { index, minutes in
                    Stepper(
                        value: Binding(
                            get: { minutes },
                            set: { shelf.setTimerPreset(at: index, minutes: $0) }
                        ),
                        in: 1...600
                    ) {
                        Text("\(minutes) min")
                            .monospacedDigit()
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                }
            }
            Toggle("Show a notification when a timer or alarm ends", isOn: $shelf.notifiesWhenTimersEnd)
            Text("Shelf always plays a sound and opens. macOS asks once before Aster can show notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsSection: some View {
        EditorSection(
            title: "Shortcuts",
            subtitle: "Pick up to \(ShelfController.maximumShortcutCount) shortcuts for Shelf. With none picked, Shelf shows the first \(ShelfController.maximumShortcutCount)."
        ) {
            if shelf.availableShortcuts.isEmpty {
                Text("No shortcuts found. Create one in the Shortcuts app, then refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shelf.availableShortcuts, id: \.self) { name in
                            let isSelected = shelf.isShortcutSelected(name)
                            Button { shelf.toggleShortcutSelection(name) } label: {
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.asterAccentLight : .secondary)
                                    Text(name).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!isSelected && !shelf.canSelectMoreShortcuts)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Text("\(shelf.selectedShortcutNames.count) of \(ShelfController.maximumShortcutCount) picked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { shelf.refreshShortcuts(force: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.asterAccentLight)
            }
        }
        .onAppear { shelf.refreshShortcuts(force: true) }
    }

    private var weatherSection: some View {
        @Bindable var shelf = shelf
        return EditorSection(title: "Weather location", subtitle: "Aster sends this city name to Open-Meteo only while the Weather widget is on.") {
            TextField("City or postal code", text: $shelf.weatherLocation)
                .textFieldStyle(.roundedBorder)
                .onSubmit { shelf.refreshWeather() }
            HStack {
                Text(shelf.weather?.locationName ?? shelf.weatherStatus ?? "No location selected")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Update") { shelf.refreshWeather() }
                    .buttonStyle(.plain).foregroundStyle(Color.asterAccentLight)
                    .disabled(shelf.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func hoverDelayLabel(_ delay: Double) -> String {
        switch delay {
        case 0: "Instantly"
        case 0.15: "A short pause"
        case 0.3: "A medium pause"
        default: "A long pause"
        }
    }
}

private struct ShelfSettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let control: () -> Content

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            control()
                .labelsHidden()
                .fixedSize()
        }
    }
}
