import AppKit
import AVFoundation
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
                        .foregroundStyle(Color.asterDeepPurple)
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
                colors: [Color.asterPurple.opacity(0.08), .clear],
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

private struct CanvasModuleView: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Binding var showImporter: Bool
    @State private var isSelectingShuffleItems = false

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            ModuleHeader(module: .canvas) {
                HStack(spacing: 12) {
                    Toggle("Enable Canvas", isOn: $controller.isEnabled)
                        .toggleStyle(.switch)
                    Button {
                        isSelectingShuffleItems.toggle()
                    } label: {
                        Label(
                            isSelectingShuffleItems ? "Done selecting" : "Select for shuffle",
                            systemImage: isSelectingShuffleItems ? "checkmark" : "shuffle"
                        )
                    }
                    .buttonStyle(AsterButtonStyle(prominent: false))
                    .disabled(!controller.isEnabled)
                    Button { showImporter = true } label: { Label("Add wallpaper", systemImage: "plus") }
                        .buttonStyle(AsterButtonStyle(prominent: true))
                        .disabled(!controller.isEnabled)
                }
            }
            HStack(spacing: 18) {
                CanvasLibrary(
                    showImporter: $showImporter,
                    isSelectingShuffleItems: $isSelectingShuffleItems
                )
                CanvasInspector(isSelectingShuffleItems: $isSelectingShuffleItems)
                    .frame(width: 300)
            }
            .padding(22)
            .disabled(!controller.isEnabled)
            .opacity(controller.isEnabled ? 1 : 0.55)
        }
        .onChange(of: library.items) { _, _ in
            controller.validateShuffleSelection(in: library)
        }
    }
}

private struct CanvasBackdrop: View {
    @Environment(WallpaperLibrary.self) private var library
    let item: WallpaperItem?

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                Color.clear
                if let item {
                    if item.kind == .image, let image = NSImage(contentsOf: library.url(for: item)) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .clipped()
                    } else if item.kind == .video {
                        CanvasVideoBackdrop(url: library.url(for: item))
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .clipped()
                    }
                    Color.black.opacity(0.57)
                    LinearGradient(
                        colors: [.black.opacity(0.18), Color.asterDeepPurple.opacity(0.13)],
                        startPoint: .top,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .animation(.easeInOut(duration: 0.24), value: item?.id)
        }
        .allowsHitTesting(false)
    }
}

private struct CanvasVideoBackdrop: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Color.black.opacity(0.2)
            }
        }
        .task(id: url) { thumbnail = await VideoThumbnailCache.image(for: url) }
    }
}

private struct CanvasLibrary: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Binding var showImporter: Bool
    @Binding var isSelectingShuffleItems: Bool
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 14) {
            if isSelectingShuffleItems {
                HStack(spacing: 10) {
                    Label("Choose wallpapers", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                    Text("\(controller.shuffleSelectionCount(in: library)) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { isSelectingShuffleItems = false }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 10) {
                TextField("Search wallpapers", text: $library.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $library.mediaFilter) {
                    ForEach(WallpaperLibrary.MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 95)
                Picker("Sort", selection: $library.sortOrder) {
                    ForEach(WallpaperLibrary.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 105)
            }
            if library.items.isEmpty {
                ContentUnavailableView {
                    Label("Make this Mac yours", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Add an image or video, or find a live wallpaper online.")
                } actions: {
                    VStack(spacing: 12) {
                        Button("Choose a file") { showImporter = true }
                            .buttonStyle(AsterButtonStyle(prominent: true))
                        HStack(spacing: 10) {
                            CanvasWallpaperSourceLink(
                                title: "MotionBGs",
                                url: URL(string: "https://motionbgs.com/")!
                            )
                            CanvasWallpaperSourceLink(
                                title: "MoeWalls",
                                url: URL(string: "https://moewalls.com/")!
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.filteredItems.isEmpty {
                ContentUnavailableView {
                    Label("No matching wallpapers", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another search or filter.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(library.filteredItems) { item in
                            WallpaperCard(
                                item: item,
                                isSelectingShuffleItems: isSelectingShuffleItems
                            )
                        }
                    }
                    .padding(1)
                }
            }
        }
        .padding(16)
        .glassPanel()
        .dropDestination(for: URL.self) { urls, _ in
            (try? library.importFiles(urls))?.isEmpty == false
        }
    }
}

private struct CanvasWallpaperSourceLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.right.square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.asterPurple)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .help("Open \(url.host ?? title) in your browser")
    }
}

private struct WallpaperCard: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    let item: WallpaperItem
    let isSelectingShuffleItems: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WallpaperThumbnail(item: item)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label(item.mediaLabel, systemImage: item.mediaSymbol)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    Button(role: .destructive) { library.remove(item) } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Canvas")
                    .padding(7)
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        ForEach(assignedDestinations) { destination in
                            Text(destination.badge)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .frame(width: 20, height: 20)
                                .background(Color.asterPurple.opacity(0.88), in: Circle())
                                .help(destination.rawValue)
                        }
                    }
                    .padding(7)
                }
                .overlay(alignment: .bottomLeading) {
                    if isSelectingShuffleItems {
                        Image(systemName: controller.isSelectedForShuffle(item) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(
                                item.canShuffle
                                    ? (controller.isSelectedForShuffle(item) ? Color.asterPurple : .white)
                                    : .gray
                            )
                            .padding(7)
                    }
                }
            Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(library.selectedID == item.id ? 0.11 : 0.04), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(library.selectedID == item.id ? Color.asterPurple : .white.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            if isSelectingShuffleItems {
                if item.canShuffle {
                    controller.toggleShuffleSelection(item)
                }
            } else {
                library.selectedID = item.id
            }
        }
        .help(item.name)
        .contextMenu {
            Button("Set as Desktop") { controller.apply(item, url: library.url(for: item)) }
            Button("Set as Manual-Lock Still") { controller.configureLockScreen(item, url: library.url(for: item)) }
                .disabled(!item.canUseAsLockScreenStill)
            Button("Set as Screen Saver") { controller.configureScreenSaver(item, url: library.url(for: item)) }
            if item.canShuffle {
                Divider()
                Button(controller.isSelectedForShuffle(item) ? "Remove from Shuffle" : "Add to Shuffle") {
                    controller.toggleShuffleSelection(item)
                }
            }
            Divider()
            Button("Remove", role: .destructive) { library.remove(item) }
        }
    }

    private var assignedDestinations: [WallpaperController.CanvasDestination] {
        WallpaperController.CanvasDestination.allCases.filter {
            controller.assignedItemID(for: $0) == item.id
        }
    }
}

private struct WallpaperThumbnail: View {
    @Environment(WallpaperLibrary.self) private var library
    let item: WallpaperItem

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                Color.black.opacity(0.25)
                if item.kind == .image, let image = NSImage(contentsOf: library.url(for: item)) {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: max(viewport.size.width, 1), height: max(viewport.size.height, 1))
                        .clipped()
                } else if item.kind == .video {
                    VideoFramePreview(url: library.url(for: item))
                        .frame(width: max(viewport.size.width, 1), height: max(viewport.size.height, 1))
                        .clipped()
                } else {
                    LinearGradient(colors: [Color.asterPurple.opacity(0.75), .indigo.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "play.fill").font(.title2)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
        }
    }
}

private struct VideoFramePreview: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.asterPurple.opacity(0.42), .black.opacity(0.42)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "film").foregroundStyle(.secondary)
            }
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .padding(8)
                .background(.black.opacity(0.52), in: Circle())
        }
        .task(id: url) {
            thumbnail = await VideoThumbnailCache.image(for: url)
        }
    }
}

@MainActor
private enum VideoThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 640, height: 400)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let image = NSImage(cgImage: result.image, size: .zero)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct CanvasInspector: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Binding var isSelectingShuffleItems: Bool

    var body: some View {
        @Bindable var controller = controller
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing").font(.headline)
                Picker("Destination", selection: $controller.editingDestination) {
                    ForEach(WallpaperController.CanvasDestination.allCases) { destination in
                        Text(destination.displayName).tag(destination)
                    }
                }
                .pickerStyle(.segmented)
                .frame(height: 28)
                Text(destinationHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Preview").font(.headline)
            Group {
                if let item = library.selectedItem { WallpaperThumbnail(item: item) }
                else { Color.white.opacity(0.03).overlay(Image(systemName: "display").font(.largeTitle).foregroundStyle(.tertiary)) }
            }
            .frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.09)))

            if let item = library.selectedItem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(item.mediaLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Fit", selection: $controller.fillMode) {
                ForEach(WallpaperController.FillMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Wallpaper shuffle", systemImage: "shuffle")
                        .font(.headline)
                    Spacer()
                    Text("\(controller.shuffleSelectionCount(in: library)) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Rotate selected images, GIFs, and videos on your Desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(controller.shuffleSelectionCount(in: library) == 0 ? "Choose images" : "Edit selection") {
                        isSelectingShuffleItems = true
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Picker("Rate", selection: $controller.shuffleRate) {
                        ForEach(WallpaperController.ShuffleRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 122)
                }
                Button {
                    if controller.isShuffling {
                        controller.stopShuffle()
                    } else {
                        controller.startShuffle(in: library)
                    }
                } label: {
                    Label(
                        controller.isShuffling ? "Stop Shuffle" : "Start Shuffle",
                        systemImage: controller.isShuffling ? "stop.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!controller.isShuffling && controller.shuffleSelectionCount(in: library) < 2)
                .buttonStyle(AsterButtonStyle(prominent: controller.isShuffling == false))
                Text(shuffleHelp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup("Smart Pause") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Pause when another app is full screen",
                        isOn: $controller.pauseMotionForFullScreenApps
                    )
                    Toggle(
                        "Pause during high system load",
                        isOn: $controller.pauseMotionForHighSystemLoad
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("CPU threshold")
                            Spacer()
                            Text("\(Int(controller.highSystemLoadThreshold))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $controller.highSystemLoadThreshold,
                            in: 50...95,
                            step: 5
                        )
                        Text("Pauses after sustained load and resumes below \(max(Int(controller.highSystemLoadThreshold) - 10, 0))%.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .disabled(!controller.pauseMotionForHighSystemLoad)
                    .opacity(controller.pauseMotionForHighSystemLoad ? 1 : 0.5)
                    Toggle(
                        "Pause while Low Power Mode is on",
                        isOn: $controller.pauseMotionInLowPowerMode
                    )
                    Text("Optional: leave this off to keep motion playing whenever the desktop is visible.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label(
                        controller.smartPauseStatusMessage,
                        systemImage: controller.isMotionWallpaperPaused
                            ? "pause.circle.fill"
                            : "gauge.with.dots.needle.33percent"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        controller.isMotionWallpaperPaused
                            ? Color.asterPurple
                            : Color.white.opacity(0.38)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .padding(.top, 8)
            }
            .font(.subheadline)

            DisclosureGroup("Playback & launch") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Resume motion wallpaper when Aster opens", isOn: $controller.autoResumeMotionWallpaper)
                    Toggle("Open Aster at login", isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.setLaunchAtLogin($0) }
                    ))
                    Text(controller.launchAtLoginStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if library.selectedItem?.kind == .video {
                        Toggle("Mute video audio", isOn: $controller.muted)
                    }
                }
                .toggleStyle(.switch)
                .padding(.top, 8)
            }
            .font(.subheadline)

            DisclosureGroup("Lock Screen details") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Automatic lock uses Screen Saver", systemImage: "sparkles.rectangle.stack")
                        .font(.caption.weight(.semibold))
                    Text("If the Screen Saver is already running when macOS locks automatically, its animation stays visible.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Manual lock and lid close use a still", systemImage: "lock.display")
                        .font(.caption.weight(.semibold))
                    Text("Choose that still under Manual-Lock Still. GIFs and videos are intentionally unavailable there.")
                        .font(.caption).foregroundStyle(.secondary)
                    if controller.screenSaverIsInstalled {
                        Button("Open Screen Saver Settings") { controller.openScreenSaverSettings() }
                            .buttonStyle(.plain)
                    }
                    Text(controller.screenSaverStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            .font(.subheadline)

            if let item = library.selectedItem {
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([library.url(for: item)]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(role: .destructive) { library.remove(item) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Label(destinationStatus, systemImage: controller.assignedItemID(for: controller.editingDestination) == nil ? "circle" : "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                if let item = library.selectedItem { controller.assign(item, url: library.url(for: item)) }
            } label: {
                Group {
                    if controller.editingDestination == .desktop && controller.isApplying {
                        Label("Applying…", systemImage: "hourglass")
                    } else {
                        Label(actionLabel, systemImage: controller.editingDestination.symbol)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(
                library.selectedItem == nil
                    || (controller.editingDestination == .desktop && controller.isApplying)
                    || lockSelectionIsMotion
            )
            .buttonStyle(AsterButtonStyle(prominent: true))
            if controller.editingDestination == .desktop && controller.isAnimating {
                Button("Stop motion wallpaper") { controller.stopAnimatedWallpaper() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .glassPanel()
    }

    private var destinationHelp: String {
        switch controller.editingDestination {
        case .desktop: "The wallpaper behind your windows."
        case .lockScreen: "A still shown after manual lock, lid close, or wake."
        case .screenSaver: "Animated while idle and retained when that session auto-locks."
        }
    }

    private var shuffleHelp: String {
        if controller.isShuffling {
            return "Running every \(controller.shuffleRate.label)."
        }
        if controller.shuffleSelectionCount(in: library) < 2 {
            return "Select at least two wallpapers."
        }
        return "Ready to change every \(controller.shuffleRate.label)."
    }

    private var destinationStatus: String {
        controller.editingDestination == .desktop
            ? controller.statusMessage
            : controller.screenSaverStatusMessage
    }

    private var actionLabel: String {
        guard let item = library.selectedItem else { return "Choose Media" }
        return switch controller.editingDestination {
        case .desktop: item.kind == .video ? "Play on Desktop" : "Set Desktop"
        case .lockScreen: lockSelectionIsMotion ? "Still Images Only" : "Set Manual-Lock Still"
        case .screenSaver: "Set Screen Saver"
        }
    }

    private var lockSelectionIsMotion: Bool {
        guard controller.editingDestination == .lockScreen,
              let item = library.selectedItem else { return false }
        return !item.canUseAsLockScreenStill
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
                Toggle("Monitor clipboard", isOn: $clipboard.isMonitoring)
                    .toggleStyle(.switch)
            }
            VStack(spacing: 0) {
                clipsToolbar
                Divider().overlay(.white.opacity(0.06))
                if !clipboard.isMonitoring && clipboard.entries.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 42)).foregroundStyle(Color.asterPurple)
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
            Button("Clear", role: .destructive) { clipboard.clearHistory() }
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
                .foregroundStyle(isActive ? Color.asterPurple : .secondary)
                .background(isActive ? Color.asterPurple.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().stroke(isActive ? Color.asterPurple.opacity(0.45) : .clear))
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
            if let url = clipboard.imageURL(for: entry), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
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

private struct ShelfModuleView: View {
    @Environment(ShelfController.self) private var shelf

    var body: some View {
        @Bindable var shelf = shelf
        VStack(spacing: 0) {
            ModuleHeader(module: .shelf) {
                Toggle("Enable Shelf", isOn: $shelf.isEnabled).toggleStyle(.switch)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                                    .foregroundStyle(Color.asterPurple)
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
                            .foregroundStyle(shelf.isEnabled ? Color.asterPurple : Color.secondary)
                            .disabled(!shelf.isEnabled)
                        }
                        .padding(16)
                        .background(.thinMaterial.opacity(0.34), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 0.7)
                        }

                        EditorSection(title: "Behavior", subtitle: "Shelf lives behind the notch and stays out of the Dock.") {
                            Toggle("Open when pointer reaches the notch", isOn: $shelf.opensOnHover)
                            Slider(value: $shelf.shelfWidth, in: 360...620) { Text("Width") }
                            HStack { Text("Shelf width"); Spacer(); Text("\(Int(shelf.shelfWidth)) px").foregroundStyle(.secondary) }
                        }
                        EditorSection(title: "Appearance", subtitle: "Keep only the details you want to see.") {
                            Toggle("Outer outline", isOn: $shelf.showsOutline)
                            Toggle("Header date", isOn: $shelf.showsHeaderDate)
                            Toggle("Header time", isOn: $shelf.showsHeaderTime)
                        }
                        EditorSection(title: "Widgets", subtitle: "Every widget is optional. Reminders asks before accessing the Reminders app; Weather only sends the city you enter.") {
                            Toggle(isOn: $shelf.showsNowPlaying) { Label("Now Playing — 2 slots", systemImage: "play.square.stack.fill") }
                            Toggle(isOn: $shelf.showsDropZone) { Label("Drop Zone — 2 slots", systemImage: "tray.and.arrow.down.fill") }
                            Toggle(isOn: $shelf.showsReminders) { Label("Reminders — 2 slots", systemImage: "checklist") }
                            Toggle(isOn: $shelf.showsShortcuts) { Label("Shortcuts — 2 slots", systemImage: "square.2.layers.3d.fill") }
                            Toggle(isOn: $shelf.showsSwitches) { Label("Switch — 2 slots", systemImage: "switch.2") }
                            Toggle(isOn: $shelf.showsCalendar) { Label("Calendar", systemImage: "calendar") }
                            Toggle(isOn: $shelf.showsTimer) { Label("Quick Timer", systemImage: "timer") }
                            Toggle(isOn: $shelf.showsAlarm) { Label("Alarm", systemImage: "alarm.fill") }
                            Toggle(isOn: $shelf.showsBattery) { Label("Battery", systemImage: "battery.100percent") }
                            Toggle(isOn: $shelf.showsSystemHealth) { Label("System Health", systemImage: "gauge.with.dots.needle.67percent") }
                            Toggle(isOn: $shelf.showsWeather) { Label("Weather", systemImage: "cloud.sun.fill") }
                            Toggle(isOn: $shelf.showsClipboard) { Label("Latest Clip", systemImage: "doc.on.clipboard") }
                        }
                        EditorSection(title: "Weather location", subtitle: "Aster sends this city name to Open-Meteo only while the Weather widget is enabled.") {
                            TextField("City or postal code", text: $shelf.weatherLocation)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { shelf.refreshWeather() }
                            HStack {
                                Text(shelf.weather?.locationName ?? shelf.weatherStatus ?? "No location selected")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button("Update") { shelf.refreshWeather() }
                                    .buttonStyle(.plain).foregroundStyle(Color.asterPurple)
                                    .disabled(shelf.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(22)
            }
        }
    }
}

private struct BarModuleView: View {
    @Environment(BarController.self) private var bar

    var body: some View {
        @Bindable var bar = bar
        VStack(spacing: 0) {
            ModuleHeader(module: .bar) { Toggle("Enable Bar", isOn: $bar.isEnabled).toggleStyle(.switch) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EditorSection(title: "Menu bar behavior", subtitle: "Aster uses native macOS status items. No Accessibility permission is needed.") {
                        Toggle("Use compact divider spacing", isOn: $bar.compactSpacing)
                        Toggle("Remember collapsed state", isOn: $bar.rememberCollapsedState)
                        if bar.isEnabled {
                            Button(bar.isCollapsed ? "Show utility icons" : "Hide utility icons") {
                                bar.toggle()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.asterPurple)
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
                            .foregroundStyle(Color.asterPurple)
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
                        .foregroundStyle(Color.asterPurple)
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
                                .foregroundStyle(Color.asterPurple)
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
                    .foregroundStyle(Color.asterPurple)
                    .frame(width: 30, height: 30)
                    .background(Color.asterPurple.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
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
                .foregroundStyle(isOn ? Color.asterPurple : .secondary)
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
                .tint(Color.asterPurple)
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
                                .font(.title2.weight(.bold)).foregroundStyle(Color.asterPurple)
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

private struct EditorSection<Content: View>: View {
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

struct SettingsView: View {
    @Environment(WallpaperController.self) private var controller
    @Environment(ClipboardManager.self) private var clipboard
    @Environment(UpdateManager.self) private var updates
    @State private var showsAsterInDock = AsterAppPresence.showsInDock()

    var body: some View {
        @Bindable var clipboard = clipboard
        @Bindable var updates = updates
        Form {
            Section("General") {
                Toggle("Launch Aster at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                Text(controller.launchAtLoginStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show Aster in Dock", isOn: Binding(
                    get: { showsAsterInDock },
                    set: { newValue in
                        showsAsterInDock = newValue
                        AsterAppPresence.setShowsInDock(newValue)
                    }
                ))
                Text("When hidden, Aster keeps running in the background and global shortcuts, Shelf, Bar, and other enabled modules continue working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Monitor clipboard", isOn: $clipboard.isMonitoring)
                Button("Delete clipboard history", role: .destructive) { clipboard.clearHistory() }
            }
            Section("Updates") {
                LabeledContent("Version", value: "\(updates.currentVersion) (\(updates.currentBuild))")
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                HStack {
                    Button(updates.updateButtonTitle) {
                        if updates.state == .updateAvailable {
                            updates.downloadAvailableUpdate()
                        } else if updates.state == .downloaded {
                            updates.openDownloadedUpdate()
                        } else {
                            updates.checkForUpdates()
                        }
                    }
                    .disabled(updates.isBusy)
                    Button("What’s New") { updates.showWhatsNew() }
                        .disabled(updates.whatsNew == nil)
                }
                Text(updates.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Aster has no account, analytics, telemetry, or advertising. Motion wallpapers require Aster to remain open.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 470)
    }
}

private struct AsterButtonStyle: ButtonStyle {
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
                tint: prominent ? Color.asterPurple.opacity(0.42) : nil
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
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
