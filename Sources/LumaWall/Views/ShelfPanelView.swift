import AppKit
import SwiftUI

struct ShelfPanelView: View {
    @Environment(ShelfController.self) private var shelf
    @Environment(ClipboardManager.self) private var clipboard
    @Environment(SwitchController.self) private var switches
    @State private var reminderDraft = ""

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: shelf.isExpanded ? 24 : 13, bottomTrailingRadius: shelf.isExpanded ? 24 : 13)
                .fill(Color.black)
            if shelf.showsOutline && shelf.isExpanded {
                UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24)
                    .fill(.clear)
                    .overlay {
                    UnevenRoundedRectangle(bottomLeadingRadius: shelf.isExpanded ? 24 : 13, bottomTrailingRadius: shelf.isExpanded ? 24 : 13)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }

            if shelf.isExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    expandedContent
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                collapsedContent
            }
        }
        .contentShape(Rectangle())
        .onHover { shelf.hoverChanged($0) }
        .animation(.easeOut(duration: 0.18), value: shelf.isExpanded)
    }

    private var collapsedContent: some View {
        HStack {
            if shelf.timerRemaining > 0 {
                Image(systemName: "timer")
                Text(durationText(shelf.timerRemaining))
            } else if let alarmDate = shelf.alarmDate {
                Image(systemName: "alarm.fill")
                Text(alarmDate, style: .time)
            }
            Spacer()
            if let level = shelf.batteryLevel {
                Text("\(level)%")
                Image(systemName: batterySymbol(level: level, charging: shelf.isCharging))
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.78))
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { shelf.toggleExpansion() }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            HStack {
                if shelf.showsHeaderDate {
                    Text(shelf.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                if shelf.showsHeaderTime {
                    Text(shelf.now, style: .time)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Button { shelf.toggleExpansion() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, shelf.showsHeaderDate || shelf.showsHeaderTime ? 14 : 8)
            .padding(.horizontal, 16)

            if shelf.showsNowPlaying {
                nowPlayingWidget
                    .padding(.horizontal, 10)
            }
            if shelf.showsDropZone {
                dropZoneWidget
                    .padding(.horizontal, 10)
            }
            if shelf.showsReminders {
                remindersWidget
                    .padding(.horizontal, 10)
            }
            if shelf.showsShortcuts {
                shortcutsWidget
                    .padding(.horizontal, 10)
            }
            if shelf.showsSwitches {
                switchesWidget
                    .padding(.horizontal, 10)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .top),
                    GridItem(.flexible(), alignment: .top)
                ],
                spacing: 9
            ) {
                if shelf.showsCalendar { calendarWidget }
                if shelf.showsTimer { timerWidget }
                if shelf.showsAlarm { alarmWidget }
                if shelf.showsBattery { batteryWidget }
                if shelf.showsSystemHealth { systemHealthWidget }
                if shelf.showsWeather { weatherWidget }
                if shelf.showsClipboard { clipboardWidget }
                if shelf.enabledWidgetCount == 0 {
                    Label("Choose widgets in Aster → Shelf", systemImage: "square.grid.2x2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .gridCellColumns(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private var dropZoneWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Drop Zone", systemImage: "tray.and.arrow.down.fill")
                    .font(.caption.weight(.semibold))
                Text("Temporary · this session")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !shelf.droppedItems.isEmpty {
                    Button("Clear") { shelf.clearDroppedItems() }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if shelf.droppedItems.isEmpty {
                HStack {
                    Spacer()
                    Label("Drop files here, then drag them into another app", systemImage: "plus")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 42)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5]))
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(shelf.droppedItems) { item in
                            HStack(spacing: 7) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                    .resizable().frame(width: 25, height: 25)
                                Text(item.name).font(.caption).lineLimit(1).frame(maxWidth: 105)
                                Button { shelf.removeDroppedItem(item) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).frame(height: 39)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .draggable(item.url)
                        }
                    }
                }
            }
        }
        .wideShelfWidget()
        .dropDestination(for: URL.self) { urls, _ in
            shelf.addDroppedFiles(urls)
        }
    }

    private var remindersWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Reminders", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { shelf.refreshReminders() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("Add a reminder", text: $reminderDraft)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit(addReminder)
                Button(action: addReminder) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Color.asterPurple)
                    .disabled(reminderDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 9).frame(height: 27)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            if shelf.reminders.isEmpty {
                Text(shelf.remindersStatus ?? "Nothing due")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ForEach(shelf.reminders.prefix(2)) { reminder in
                    HStack(spacing: 7) {
                        Button { shelf.completeReminder(reminder) } label: {
                            Image(systemName: "circle").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.asterPurple)
                        Text(reminder.name).font(.caption).lineLimit(1)
                    }
                }
            }
        }
        .wideShelfWidget()
    }

    private var shortcutsWidget: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Shortcuts", systemImage: "square.2.layers.3d.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let status = shelf.shortcutStatus {
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Button { shelf.refreshShortcuts() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
            if shelf.shortcuts.isEmpty {
                Text(shelf.shortcutStatus ?? "No shortcuts found")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(shelf.shortcuts, id: \.self) { shortcut in
                        Button { shelf.runShortcut(shortcut) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "play.fill").font(.system(size: 8))
                                Text(shortcut).font(.caption).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 9).frame(height: 27)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .wideShelfWidget()
    }

    private var nowPlayingWidget: some View {
        HStack(spacing: 13) {
            Group {
                if let artwork = shelf.nowPlayingArtwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color.asterPurple.opacity(0.72), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.8)))
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shelf.nowPlayingTitle ?? "Nothing playing")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(shelf.nowPlayingTitle == nil ? "Media from apps and browsers appears here" : shelf.nowPlayingSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let app = shelf.nowPlayingApp {
                        Text(app).font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if shelf.nowPlayingDuration > 0 {
                    ProgressView(value: shelf.currentPlaybackPosition, total: shelf.nowPlayingDuration)
                        .tint(Color.asterPurple)
                }

                HStack(spacing: 18) {
                    Spacer()
                    mediaButton("backward.fill", action: shelf.previousTrack)
                    mediaButton(shelf.nowPlayingIsPlaying ? "pause.fill" : "play.fill", prominent: true, action: shelf.togglePlayback)
                    mediaButton("forward.fill", action: shelf.nextTrack)
                    Spacer()
                }
                .disabled(shelf.nowPlayingApp == nil)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private var switchesWidget: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Switch", systemImage: "switch.2")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(switches.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 7) {
                shelfSwitchButton(
                    "Awake",
                    symbol: "cup.and.heat.waves.fill",
                    isOn: switches.keepsMacAwake,
                    action: { switches.setKeepAwake(!switches.keepsMacAwake) }
                )
                shelfSwitchButton(
                    "Display",
                    symbol: "display",
                    isOn: switches.keepsDisplayAwake,
                    action: { switches.setKeepDisplayAwake(!switches.keepsDisplayAwake) }
                )
                shelfSwitchButton(
                    "Desktop",
                    symbol: "eye.slash.fill",
                    isOn: switches.hidesDesktopIcons,
                    action: { switches.setDesktopIconsHidden(!switches.hidesDesktopIcons) }
                )
                shelfSwitchButton(
                    "Dark",
                    symbol: "moon.fill",
                    isOn: switches.usesDarkMode,
                    action: { switches.setDarkMode(!switches.usesDarkMode) }
                )
            }
            Spacer(minLength: 0)
        }
        .wideShelfWidget()
    }

    private var calendarWidget: some View {
        Button { shelf.openCalendar() } label: {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text(Date.now.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red)
                    Text(Date.now.formatted(.dateTime.day()))
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Calendar").font(.caption.weight(.semibold))
                    Text("Open today").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .shelfWidget()
        }
        .buttonStyle(.plain)
    }

    private var timerWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Timer", systemImage: "timer").font(.caption.weight(.semibold))
                Spacer()
                if shelf.timerRemaining > 0 {
                    Button("Cancel") { shelf.cancelTimer() }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if shelf.timerRemaining > 0 {
                Text(durationText(shelf.timerRemaining))
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
            } else {
                HStack(spacing: 6) {
                    timerButton(5)
                    timerButton(15)
                    timerButton(25)
                }
            }
            Spacer(minLength: 0)
        }
        .shelfWidget()
    }

    private var batteryWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Battery", systemImage: shelf.isCharging ? "bolt.fill" : "battery.100percent")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(shelf.isCharging ? "Charging" : "Mac")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let level = shelf.batteryLevel {
                Text("\(level)%")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                ProgressView(value: Double(level), total: 100)
                    .tint(level < 20 ? .red : Color.asterPurple)
            } else {
                Text("Power connected").font(.subheadline)
                Text("No internal battery").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .shelfWidget()
    }

    private var alarmWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Alarm", systemImage: "alarm.fill").font(.caption.weight(.semibold))
                Spacer()
                if shelf.alarmDate != nil {
                    Button("Cancel") { shelf.cancelAlarm() }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let alarmDate = shelf.alarmDate {
                Text(alarmDate, style: .time)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                Text(alarmDate.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    alarmButton("30m") { shelf.setAlarm(minutesFromNow: 30) }
                    alarmButton("1h") { shelf.setAlarm(minutesFromNow: 60) }
                    alarmButton("8am") { shelf.setMorningAlarm() }
                }
            }
            Spacer(minLength: 0)
        }
        .shelfWidget()
    }

    private var clipboardWidget: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Latest clip", systemImage: clipboard.entries.first?.kind.symbol ?? "doc.on.clipboard")
                .font(.caption.weight(.semibold))
            if let entry = clipboard.entries.first {
                Text(entry.displayText)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Copy again") { clipboard.copy(entry) }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.asterPurple)
            } else {
                Text(clipboard.isMonitoring ? "Copy something to see it here." : "Enable Clips to show recent items.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .shelfWidget()
    }

    private var systemHealthWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This Mac", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption.weight(.semibold))
            healthRow("CPU", value: shelf.systemHealth.cpuUsage)
            healthRow("Memory", value: shelf.systemHealth.memoryUsage)
            healthRow("Storage", value: shelf.systemHealth.storageUsage)
            Spacer(minLength: 0)
        }
        .shelfWidget()
    }

    private var weatherWidget: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Weather", systemImage: shelf.weather?.symbol ?? "cloud.sun.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button { shelf.refreshWeather() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
            }
            if shelf.weatherIsLoading {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption2).foregroundStyle(.secondary)
            } else if let weather = shelf.weather {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(weather.temperature.rounded()))\(weather.unit)")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                    Spacer()
                    Text("H \(Int(weather.high.rounded()))°  L \(Int(weather.low.rounded()))°")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(weather.locationName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(shelf.weatherStatus ?? "Set a city in Aster")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .shelfWidget()
    }

    private func timerButton(_ minutes: Int) -> some View {
        Button("\(minutes)m") { shelf.startTimer(minutes: minutes) }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func alarmButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mediaButton(_ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 13 : 11, weight: .semibold))
                .frame(width: prominent ? 30 : 24, height: prominent ? 30 : 24)
                .background(prominent ? Color.asterPurple.opacity(0.78) : .white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func shelfSwitchButton(
        _ title: String,
        symbol: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 57)
            .background(
                isOn ? Color.asterPurple.opacity(0.72) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(isOn ? Color.green : Color.clear)
                    .frame(width: 5, height: 5)
                    .padding(7)
            }
        }
        .buttonStyle(.plain)
    }

    private func healthRow(_ label: String, value: Double) -> some View {
        HStack(spacing: 7) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            ProgressView(value: value).tint(Color.asterPurple)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption2.monospacedDigit()).frame(width: 28, alignment: .trailing)
        }
    }

    private func addReminder() {
        if shelf.addReminder(reminderDraft) { reminderDraft = "" }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded(.up)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        if level <= 10 { return "battery.0percent" }
        if level <= 35 { return "battery.25percent" }
        if level <= 65 { return "battery.50percent" }
        if level <= 90 { return "battery.75percent" }
        return "battery.100percent"
    }
}

private extension View {
    func shelfWidget() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
    }

    func wideShelfWidget() -> some View {
        self
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
    }
}
