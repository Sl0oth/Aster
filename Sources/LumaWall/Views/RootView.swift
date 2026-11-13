import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Environment(ClipboardManager.self) private var clipboard
    @Environment(ShelfController.self) private var shelf
    @Environment(BarController.self) private var bar
    @Environment(SwitchController.self) private var switches
    @Environment(UpdateManager.self) private var updates
    @State private var selectedModule: AsterModule = AsterModuleSelection.initialModuleForLaunch()
    @State private var isImporterPresented = false
    @State private var importError: String?
    @State private var showsUpdateDetails = false
    @State private var seenModuleIntroductions: Set<AsterModule> = Set(
        (UserDefaults.standard.stringArray(forKey: "Aster.ModuleIntroductions.seen") ?? [])
            .compactMap { AsterModule(rawValue: $0) }
    )

    var body: some View {
        ZStack {
            AsterBackground()
            if selectedModule == .canvas, controller.isEnabled {
                CanvasBackdrop(item: library.selectedItem)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Aster")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.asterAccentDeep)
                    Spacer()
                    if updates.state == .updateAvailable || updates.state == .downloading || updates.state == .downloaded {
                        Button { showsUpdateDetails = true } label: {
                            HStack(spacing: 7) {
                                Image(systemName: updates.state == .downloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                Text(updates.state == .downloaded ? "Update downloaded" : updates.state == .downloading ? "Downloading update…" : "Update available")
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(.white.opacity(0.055), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.07), lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .frame(height: 44)
                .background(.ultraThinMaterial.opacity(selectedModule == .canvas ? 0.10 : 0.25))

                HStack(spacing: 0) {
                    AsterSidebar(selection: $selectedModule)
                    moduleContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .asterAccentAware()
        .background(TransparentWindowConfigurator().allowsHitTesting(false))
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            do { _ = try library.importFiles(result.get()) }
            catch { importError = error.localizedDescription }
        }
        .alert("Couldn’t Import", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Unknown error")
        }
        .sheet(isPresented: $showsUpdateDetails) {
            UpdateDetailsView()
                .environment(updates)
        }
        .onChange(of: updates.state) { _, newState in
            if newState == .updateAvailable {
                showsUpdateDetails = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importWallpaper)) { _ in
            selectedModule = .canvas
            isImporterPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAsterBar)) { _ in
            selectedModule = .bar
        }
        .onReceive(NotificationCenter.default.publisher(for: .asterIntroductionsReset)) { _ in
            seenModuleIntroductions = []
        }
        .task {
            shelf.activate(clipboard: clipboard, switches: switches)
            controller.validateAssignments(in: library)
            controller.validateShuffleSelection(in: library)
            // Let AppKit finish creating the desktop and app windows before
            // restoring the player. This avoids a launch-order race on login.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            controller.restoreShuffleIfNeeded(in: library)
            if !controller.isShuffling {
                controller.restoreMotionWallpaperIfNeeded(from: library)
            }
        }
        .overlay {
            if updates.presentsWhatsNew, let release = updates.whatsNew {
                WhatsNewView(release: release, dismiss: updates.dismissWhatsNew)
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
    }

    @ViewBuilder
    private var moduleContent: some View {
        ZStack {
            switch selectedModule {
            case .home:
                HomeView(openModule: { selectedModule = $0 })
            case .canvas:
                CanvasModuleView(showImporter: $isImporterPresented)
            case .clips:
                ClipsModuleView()
            case .shelf:
                ShelfModuleView()
            case .bar:
                BarModuleView()
            case .switchboard:
                SwitchModuleView()
            case .keys:
                KeysModuleView()
            case .ask:
                AskModuleView()
            }

            if selectedModule != .home,
               !seenModuleIntroductions.contains(selectedModule) {
                ModuleIntroductionView(module: selectedModule) {
                    dismissIntroduction(for: selectedModule)
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: selectedModule)
    }

    private func dismissIntroduction(for module: AsterModule) {
        withAnimation(.easeInOut(duration: 0.24)) {
            _ = seenModuleIntroductions.insert(module)
        }
        UserDefaults.standard.set(
            seenModuleIntroductions.map(\.rawValue).sorted(),
            forKey: "Aster.ModuleIntroductions.seen"
        )
    }
}

private struct AsterBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.16)
            RadialGradient(
                colors: [Color.asterAccent.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 720
            )
        }
        .ignoresSafeArea()
    }
}

private struct AsterSidebar: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(ShortcutStore.self) private var shortcuts
    @Binding var selection: AsterModule

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 6) {
                ForEach(AsterModule.visibleCases) { module in
                    let action = module.shortcutAction ?? .openHome
                    let shortcut = shortcuts.isDisabled(action) ? nil : shortcuts.binding(for: action)
                    Button { selection = module } label: {
                        HStack(spacing: 12) {
                            Image(systemName: module.symbol)
                                .frame(width: 20)
                                .foregroundStyle(selection == module ? module.accent : .secondary)
                            Text(module.title).font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            selection == module ? Color.white.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        // Make the whole row clickable, not just the icon and title.
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .optionalKeyboardShortcut(shortcut)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 208)
        .background(.ultraThinMaterial.opacity(0.48))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.05)).frame(width: 1) }
    }
}

private struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TransparentWindowHostView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TransparentWindowHostView)?.configureWindow()
    }
}

@MainActor
private final class TransparentWindowHostView: NSView {
    private var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
        window.identifier = AsterWindowRouter.mainWindowIdentifier
        window.isReleasedWhenClosed = false
        installTitleBarDoubleClickMonitor(for: window)
    }

    private func installTitleBarDoubleClickMonitor(for window: NSWindow) {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window,
                  event.window === window,
                  event.clickCount == 2 else { return event }

            let point = event.locationInWindow
            let distanceFromTop = window.frame.height - point.y
            let avoidsTrafficLights = point.x > 90
            guard distanceFromTop <= 82, avoidsTrafficLights else { return event }

            window.performZoom(nil)
            return nil
        }
    }
}

private struct HomeView: View {
    let openModule: (AsterModule) -> Void
    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Mac, your way.")
                        .font(.system(size: 40, weight: .semibold))
                    Text("Private utilities that stay out of your way.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AsterModule.visibleCases.filter { $0 != .home }) { module in
                        ModuleCard(module: module) { openModule(module) }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Free. Private. Yours.")
                        .font(.headline)
                    Text("No account, analytics, or advertising. Aster only activates the modules you choose, and keeps their data on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                .padding(.top, 6)
            }
            .padding(32)
        }
    }
}

private struct ModuleCard: View {
    let module: AsterModule
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: module.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(module.accent)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.title).font(.headline)
                    Text(module.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .asterGlass(cornerRadius: 16, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

struct ModuleHeader<Trailing: View>: View {
    let module: AsterModule
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(module.title, systemImage: module.symbol)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(module.accent)
                Text(module.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial.opacity(0.22))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
}

private struct ClipsModuleView: View {
    @Environment(ClipboardManager.self) private var clipboard
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var activeBoardID: ClipboardBoard.ID?
    @State private var isAddingBoard = false
    @State private var newBoardName = ""
    @State private var boardToRename: ClipboardBoard?
    @State private var renamedBoardName = ""
    @State private var isConfirmingClear = false
    @State private var showsOptions = false

    var body: some View {
        @Bindable var clipboard = clipboard
        let visibleEntries = clipboard.filteredEntries(in: activeBoardID)
        VStack(spacing: 0) {
            ModuleHeader(module: .clips) {
                Label(
                    shortcuts.isDisabled(.showClipsGlobally)
                        ? "Shortcut disabled"
                        : shortcuts.binding(for: .showClipsGlobally).display,
                    systemImage: "keyboard"
                )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if clipboard.isMonitoring && clipboard.isCapturePaused {
                    Button("Capture paused — Resume") { clipboard.isCapturePaused = false }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.asterAccentLight)
                }
                Toggle("Monitor clipboard", isOn: $clipboard.isMonitoring)
                    .toggleStyle(.switch)
                Button { showsOptions.toggle() } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(AsterButtonStyle(prominent: false))
                .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
                    ClipsOptionsView()
                        .environment(clipboard)
                        .padding(18)
                        .frame(width: 360)
                }
            }
            VStack(spacing: 0) {
                clipsToolbar
                Divider().overlay(.white.opacity(0.06))
                if !clipboard.isMonitoring && clipboard.entries.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 42)).foregroundStyle(Color.asterAccent)
                        Text("Clipboard history is off").font(.title2.weight(.semibold))
                        Text("Aster only watches your clipboard after you enable it. Password managers and Keychain are ignored automatically.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Button("Enable Clips") { clipboard.isMonitoring = true }
                            .buttonStyle(AsterButtonStyle(prominent: true))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleEntries.isEmpty {
                    ContentUnavailableView {
                        Label(clipboard.searchText.isEmpty ? "Nothing here yet" : "No matches", systemImage: "clipboard")
                    } description: {
                        Text(emptyDescription)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 205, maximum: 320), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(visibleEntries) { entry in
                                ClipboardPreviewCard(entry: entry, activeBoardID: activeBoardID)
                            }
                        }
                        .padding(14)
                    }
                    .defaultScrollAnchor(.top)
                    .id("clips-wrapping-grid")
                }
            }
            .glassPanel(cornerRadius: 20)
            .padding(22)
        }
        .onChange(of: clipboard.boards) { _, boards in
            if let activeBoardID, !boards.contains(where: { $0.id == activeBoardID }) {
                self.activeBoardID = nil
            }
        }
        .alert("Rename Board", isPresented: Binding(
            get: { boardToRename != nil },
            set: { if !$0 { boardToRename = nil } }
        )) {
            TextField("Board name", text: $renamedBoardName)
            Button("Cancel", role: .cancel) { boardToRename = nil }
            Button("Save") {
                if let boardToRename { clipboard.renameBoard(boardToRename.id, to: renamedBoardName) }
                boardToRename = nil
            }
        }
        .alert("Clear clipboard history?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { clipboard.clearHistory() }
        } message: {
            Text(ClipsCopy.clearHistoryMessage(boardClipCount: clipboard.boardClipCount))
        }
    }

    private var clipsToolbar: some View {
        @Bindable var clipboard = clipboard
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search clipboard…", text: $clipboard.searchText)
                .textFieldStyle(.plain)
                .frame(width: 170)
            Divider().frame(height: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ClipboardBoardChip(label: "Clipboard", isActive: activeBoardID == nil) {
                        activeBoardID = nil
                    }
                    ForEach(clipboard.boards) { board in
                        ClipboardBoardChip(label: board.name, isActive: activeBoardID == board.id) {
                            activeBoardID = board.id
                        }
                        .contextMenu {
                            Button("Rename") {
                                renamedBoardName = board.name
                                boardToRename = board
                            }
                            Button("Delete Board", role: .destructive) {
                                clipboard.deleteBoard(board.id)
                            }
                        }
                    }
                    if isAddingBoard {
                        TextField("Board name…", text: $newBoardName)
                            .textFieldStyle(.plain)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(width: 120, height: 27)
                            .background(.white.opacity(0.07), in: Capsule())
                            .onSubmit(createBoard)
                    } else {
                        Button { isAddingBoard = true } label: {
                            Image(systemName: "plus").frame(width: 25, height: 25)
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.07), in: Circle())
                        .help("New board")
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(clipboard.entries.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Button("Clear…", role: .destructive) { isConfirmingClear = true }
                .buttonStyle(.plain)
                .font(.caption)
                .disabled(clipboard.entries.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var emptyDescription: String {
        if !clipboard.searchText.isEmpty { return "Try a different word or app name." }
        if activeBoardID != nil { return "Add clips from a card’s board menu." }
        return "New text and images you copy will appear here."
    }

    private func createBoard() {
        if let board = clipboard.createBoard(named: newBoardName) {
            activeBoardID = board.id
        }
        newBoardName = ""
        isAddingBoard = false
    }
}

struct ClipboardBoardChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 27)
                .foregroundStyle(isActive ? Color.asterAccent : .secondary)
                .background(isActive ? Color.asterAccent.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().stroke(isActive ? Color.asterAccent.opacity(0.45) : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct ClipboardPreviewCard: View {
    @Environment(ClipboardManager.self) private var clipboard
    let entry: ClipboardEntry
    let activeBoardID: ClipboardBoard.ID?
    var onCopy: (@MainActor () -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        Group {
            if entry.kind == .image, let url = clipboard.imageURL(for: entry) {
                card.draggable(url)
            } else {
                card.draggable(entry.text)
            }
        }
        .contextMenu { cardMenu }
    }

    private var card: some View {
        VStack(spacing: 0) {
            clipPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(11)
                .clipped()
            HStack(spacing: 5) {
                Text(entry.sourceApp ?? "Unknown")
                    .lineLimit(1)
                Text("·")
                Text(entry.createdAt, style: .relative)
                Spacer()
                Image(systemName: entry.kind.symbol)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(.white.opacity(0.035))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 235)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(isHovering ? 0.14 : 0.07))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                HStack(spacing: 4) {
                    Menu {
                        if clipboard.boards.isEmpty {
                            Text("No boards yet")
                        } else {
                            ForEach(clipboard.boards) { board in
                                Button {
                                    clipboard.toggle(entry, in: board.id)
                                } label: {
                                    Label(
                                        board.name,
                                        systemImage: clipboard.contains(entry, in: board.id) ? "checkmark" : "plus"
                                    )
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus").clipActionButton()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    Button(role: .destructive) {
                        clipboard.remove(entry, from: activeBoardID)
                    } label: {
                        Image(systemName: "xmark").clipActionButton(danger: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(7)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture {
            clipboard.copy(entry)
            onCopy?()
        }
        .help("Click to copy")
    }

    @ViewBuilder
    private var clipPreview: some View {
        switch entry.kind {
        case .image:
            if let url = clipboard.imageURL(for: entry) {
                ClipImageThumbnail(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                unavailablePreview("Image unavailable", symbol: "photo")
            }
        case .color:
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(parsedColor)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
                Text(entry.text).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Label("Link", systemImage: "arrow.up.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(9)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
        case .text:
            ScrollView {
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var cardMenu: some View {
        Button("Copy") {
            clipboard.copy(entry)
            onCopy?()
        }
        if !clipboard.boards.isEmpty {
            Menu("Boards") {
                ForEach(clipboard.boards) { board in
                    Button {
                        clipboard.toggle(entry, in: board.id)
                    } label: {
                        Label(board.name, systemImage: clipboard.contains(entry, in: board.id) ? "checkmark" : "plus")
                    }
                }
            }
        }
        Divider()
        Button(activeBoardID == nil ? "Delete" : "Remove from Board", role: .destructive) {
            clipboard.remove(entry, from: activeBoardID)
        }
    }

    private func unavailablePreview(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var parsedColor: Color {
        var hex = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 || hex.count == 4 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(hex, radix: 16) else { return .clear }
        let hasAlpha = hex.count == 8
        return Color(
            red: Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
            green: Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
            blue: Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
            opacity: hasAlpha ? Double(value & 0xff) / 255 : 1
        )
    }
}

private extension View {
    func clipActionButton(danger: Bool = false) -> some View {
        self
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(danger ? Color.red.opacity(0.72) : .black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct BarModuleView: View {
    @Environment(BarController.self) private var bar
    @Environment(ShortcutStore.self) private var shortcuts

    var body: some View {
        @Bindable var bar = bar
        VStack(spacing: 0) {
            ModuleHeader(module: .bar) { Toggle("Enable Bar", isOn: $bar.isEnabled).toggleStyle(.switch) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EditorSection(title: "Menu bar behavior", subtitle: "Aster uses native macOS status items. No Accessibility permission is needed.") {
                        Toggle("Use compact divider spacing", isOn: $bar.compactSpacing)
                        Toggle("Remember collapsed state", isOn: $bar.rememberCollapsedState)
                        HStack {
                            Text("Hide icons again")
                            Spacer()
                            Picker("Hide icons again", selection: $bar.autoCollapseDelay) {
                                ForEach(BarController.autoCollapseChoices, id: \.self) { seconds in
                                    Text(seconds == 0 ? "Never" : "After \(seconds) seconds").tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        HStack {
                            Text("Keyboard shortcut")
                            Spacer()
                            Text(shortcuts.isDisabled(.toggleBar)
                                 ? "Off"
                                 : shortcuts.binding(for: .toggleBar).display)
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(bar.hotkeyError ?? "Shows or hides the icons from any app. Change or turn it off in Keys.")
                            .font(.caption)
                            .foregroundStyle(bar.hotkeyError == nil ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if bar.isEnabled {
                            Button(bar.isCollapsed ? "Show utility icons" : "Hide utility icons") {
                                bar.toggle()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.asterAccent)
                        }
                    }
                    EditorSection(title: "Icon spacing", subtitle: "Changes the spacing between real menu-bar items across macOS.") {
                        HStack {
                            Text("Tight").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $bar.menuBarSpacingOffset, in: -12...12, step: 2)
                            Text("Wide").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(bar.menuBarSpacingLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") {
                                bar.resetMenuBarSpacing()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(bar.isApplyingMenuBarSpacing || Int(bar.menuBarSpacingOffset) == 0)
                            Button("Apply") {
                                bar.applyMenuBarSpacing()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.asterAccent)
                            .disabled(bar.isApplyingMenuBarSpacing || !bar.hasUnappliedMenuBarSpacing)
                        }
                        Text(bar.spacingStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    EditorSection(title: "Arrange real app icons", subtitle: "macOS saves the order after you move an icon.") {
                        Label("Hold Command (⌘)", systemImage: "command")
                        Text("Drag the thin divider to the right edge of the utility icons you want hidden, then place Aster immediately to its right.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Everything left of the divider collapses. Icons to its right stay visible.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Wi-Fi, battery, and other status icons work too—Command-drag each one to the divider’s left.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Restore Aster menu-bar controls") {
                            bar.resetStatusItemPositions()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.asterAccent)
                    }
                    EditorSection(title: "Privacy", subtitle: "Bar does not record clicks, keystrokes, or app usage.") {
                        Label("No Accessibility permission required", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    }
                    Label(bar.statusMessage, systemImage: bar.isCollapsed ? "rectangle.compress.vertical" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(22)
            }
        }
    }
}

private struct SwitchModuleView: View {
    @Environment(SwitchController.self) private var switches
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .switchboard) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(switches.isApplying ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(switches.isApplying ? "Applying…" : switches.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Toggle("Enable Switch", isOn: Binding(
                        get: { switches.isEnabled },
                        set: { switches.isEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("The controls you reach for most.")
                            .font(.system(size: 30, weight: .semibold))
                        Text("No menu hunting, account, or background service. Every switch uses a macOS setting or an activity owned by Aster.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 680, alignment: .leading)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        SwitchGroup(
                            title: "Power",
                            subtitle: "Temporarily override automatic sleep.",
                            symbol: "bolt.fill"
                        ) {
                            MacSwitchRow(
                                title: "Keep Mac Awake",
                                detail: "Prevents idle system sleep while Aster is open.",
                                symbol: "cup.and.heat.waves.fill",
                                isOn: binding(\.keepsMacAwake, set: switches.setKeepAwake)
                            )
                            MacSwitchRow(
                                title: "Keep Display Awake",
                                detail: "Stops the screen from sleeping automatically.",
                                symbol: "display",
                                isOn: binding(\.keepsDisplayAwake, set: switches.setKeepDisplayAwake)
                            )
                        }

                        SwitchGroup(
                            title: "Sound",
                            subtitle: "Silence output or input instantly.",
                            symbol: "speaker.wave.2.fill"
                        ) {
                            MacSwitchRow(
                                title: "Mute System Audio",
                                detail: "Mutes speakers and connected audio outputs.",
                                symbol: "speaker.slash.fill",
                                isOn: binding(\.mutesSystemAudio, set: switches.setSystemAudioMuted)
                            )
                            MacSwitchRow(
                                title: "Mute Microphone",
                                detail: "Sets input volume to zero and remembers its level.",
                                symbol: "microphone.slash.fill",
                                isOn: binding(\.mutesMicrophone, set: switches.setMicrophoneMuted)
                            )
                        }

                        SwitchGroup(
                            title: "Desktop",
                            subtitle: "Change what Finder shows.",
                            symbol: "desktopcomputer"
                        ) {
                            MacSwitchRow(
                                title: "Hide Desktop Icons",
                                detail: "Keeps files in place but clears the desktop view.",
                                symbol: "eye.slash.fill",
                                isOn: binding(\.hidesDesktopIcons, set: switches.setDesktopIconsHidden)
                            )
                            MacSwitchRow(
                                title: "Click Wallpaper to Reveal Desktop",
                                detail: "Moves windows aside when you click an open area of the wallpaper.",
                                symbol: "rectangle.on.rectangle.slash",
                                isOn: binding(
                                    \.revealsDesktopOnWallpaperClick,
                                    set: switches.setRevealDesktopOnWallpaperClick
                                )
                            )
                            MacSwitchRow(
                                title: "Show Hidden Files",
                                detail: "Reveals dotfiles and other hidden Finder items.",
                                symbol: "folder.badge.questionmark",
                                isOn: binding(\.showsHiddenFiles, set: switches.setHiddenFilesShown)
                            )
                            MacSwitchRow(
                                title: "Show File Extensions",
                                detail: "Displays extensions such as .png and .mov.",
                                symbol: "doc.badge.gearshape",
                                isOn: binding(\.showsFileExtensions, set: switches.setFileExtensionsShown)
                            )
                        }

                        SwitchGroup(
                            title: "Finder Windows",
                            subtitle: "Keep location details within reach.",
                            symbol: "folder.fill"
                        ) {
                            MacSwitchRow(
                                title: "Show Path Bar",
                                detail: "Displays the current folder path at the bottom.",
                                symbol: "point.bottomleft.forward.to.point.topright.scurvepath",
                                isOn: binding(\.showsFinderPathBar, set: switches.setFinderPathBarShown)
                            )
                            MacSwitchRow(
                                title: "Show Status Bar",
                                detail: "Shows item counts and available disk space.",
                                symbol: "info.rectangle",
                                isOn: binding(\.showsFinderStatusBar, set: switches.setFinderStatusBarShown)
                            )
                        }

                        SwitchGroup(
                            title: "Appearance",
                            subtitle: "Change the system chrome quickly.",
                            symbol: "circle.lefthalf.filled"
                        ) {
                            MacSwitchRow(
                                title: "Dark Mode",
                                detail: "Switches the macOS system appearance.",
                                symbol: "moon.fill",
                                isOn: binding(\.usesDarkMode, set: switches.setDarkMode)
                            )
                            MacSwitchRow(
                                title: "Automatically Hide Dock",
                                detail: "Shows the Dock only when the pointer reaches it.",
                                symbol: "dock.rectangle",
                                isOn: binding(\.automaticallyHidesDock, set: switches.setDockAutoHide)
                            )
                            MacSwitchRow(
                                title: "Dock Magnification",
                                detail: "Enlarges Dock icons as the pointer passes over them.",
                                symbol: "plus.magnifyingglass",
                                isOn: binding(\.usesDockMagnification, set: switches.setDockMagnification)
                            )
                            MacSwitchRow(
                                title: "Automatically Hide Menu Bar",
                                detail: "Reveals the menu bar when the pointer reaches the top.",
                                symbol: "menubar.arrow.up.rectangle",
                                isOn: binding(\.automaticallyHidesMenuBar, set: switches.setMenuBarAutoHide)
                            )
                        }

                        SwitchGroup(
                            title: "Screenshots",
                            subtitle: "Choose what macOS shows after capture.",
                            symbol: "camera.viewfinder"
                        ) {
                            MacSwitchRow(
                                title: "Floating Thumbnail",
                                detail: "Shows a temporary preview after taking a screenshot.",
                                symbol: "photo.badge.checkmark",
                                isOn: binding(\.showsScreenshotThumbnail, set: switches.setScreenshotThumbnailShown)
                            )
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Label("Private by construction", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(Color.asterAccent)
                            SwitchAssuranceRow(text: "No telemetry or remote requests")
                            SwitchAssuranceRow(text: "No Accessibility permission")
                            SwitchAssuranceRow(text: "Sleep overrides end when Aster quits")
                            SwitchAssuranceRow(text: "Finder and Dock restart only when required")
                            Spacer(minLength: 0)
                            Text("Dark Mode may ask once for permission to control System Events.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                        .glassPanel(cornerRadius: 20)
                    }
                    .disabled(!switches.isEnabled)
                    .opacity(switches.isEnabled ? 1 : 0.55)
                }
                .padding(26)
            }
        }
        .onAppear { switches.refreshSystemState() }
    }

    private func binding(
        _ keyPath: KeyPath<SwitchController, Bool>,
        set: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { switches[keyPath: keyPath] },
            set: { value in
                MainActor.assumeIsolated { set(value) }
            }
        )
    }
}

private struct SwitchGroup<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.asterAccent)
                    .frame(width: 30, height: 30)
                    .background(Color.asterAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 13)

            VStack(spacing: 0) {
                content()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .glassPanel(cornerRadius: 20)
    }
}

private struct MacSwitchRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.asterAccent : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.asterAccent)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.045)).frame(height: 1)
        }
    }
}

private struct SwitchAssuranceRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
    }
}

private struct AskModuleView: View {
    @AppStorage("Aster.Ask.enabled") private var isEnabled = false
    @AppStorage("Aster.Ask.modelChoice") private var modelChoice = "Local"

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .ask) { Toggle("Enable Ask", isOn: $isEnabled).toggleStyle(.switch) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("AI, without the ambush", systemImage: "wand.and.stars")
                                .font(.title2.weight(.bold)).foregroundStyle(Color.asterAccent)
                            Text("Ask is optional. Local models stay offline. Cloud providers only receive the text you deliberately send, using a key stored in Keychain.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No background uploads", systemImage: "checkmark.circle.fill")
                            Label("No training on your data", systemImage: "checkmark.circle.fill")
                            Label("No key stored in settings files", systemImage: "checkmark.circle.fill")
                        }
                        .font(.subheadline).foregroundStyle(.green)
                        .padding(20).frame(width: 290, alignment: .leading).glassPanel()
                    }
                    EditorSection(title: "Choose how Ask works", subtitle: "A provider is never selected for you.") {
                        Picker("Model", selection: $modelChoice) {
                            Text("Local on-device").tag("Local")
                            Text("Bring your own key").tag("Cloud")
                        }
                        .pickerStyle(.segmented)
                        Text(modelChoice == "Local" ? "Local model support will use Apple’s on-device frameworks where available." : "Provider setup will store credentials in macOS Keychain and show exactly what is sent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(22)
            }
        }
    }
}

struct EditorSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(.white.opacity(0.06))
            content()
        }
        .padding(17)
        .glassPanel(cornerRadius: 17)
    }
}

struct AsterButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15).frame(height: 38)
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .asterGlass(
                cornerRadius: 12,
                interactive: true,
                tint: prominent ? Color.asterAccent.opacity(0.42) : nil
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    func asterGlass(
        cornerRadius: CGFloat,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(tint).interactive(interactive),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            asterLegacyGlass(cornerRadius: cornerRadius)
        }
        #else
        asterLegacyGlass(cornerRadius: cornerRadius)
        #endif
    }

    func asterLegacyGlass(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    func glassPanel(cornerRadius: CGFloat = 19) -> some View {
        background(.thinMaterial.opacity(0.38), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 0.7)
            )
    }
}
