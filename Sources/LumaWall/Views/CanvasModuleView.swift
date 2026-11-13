import AppKit
import AVFoundation
import ImageIO
import SwiftUI

struct CanvasModuleView: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Binding var showImporter: Bool
    @State private var isSelectingShuffleItems = false
    @State private var itemToRename: WallpaperItem?
    @State private var renamedName = ""
    @State private var itemToRemove: WallpaperItem?

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            ModuleHeader(module: .canvas) {
                HStack(spacing: 12) {
                    Toggle("Enable Canvas", isOn: $controller.isEnabled)
                        .toggleStyle(.switch)
                    Button { showImporter = true } label: { Label("Add wallpaper", systemImage: "plus") }
                        .buttonStyle(AsterButtonStyle(prominent: true))
                        .disabled(!controller.isEnabled)
                }
            }
            HStack(spacing: 18) {
                CanvasLibraryPanel(
                    showImporter: $showImporter,
                    isSelectingShuffleItems: $isSelectingShuffleItems,
                    rename: beginRenaming,
                    remove: { itemToRemove = $0 }
                )
                CanvasInspector(
                    isSelectingShuffleItems: $isSelectingShuffleItems,
                    rename: beginRenaming,
                    remove: { itemToRemove = $0 }
                )
                .frame(width: 320)
            }
            .padding(22)
            .disabled(!controller.isEnabled)
            .opacity(controller.isEnabled ? 1 : 0.55)
        }
        .onChange(of: library.items) { _, _ in
            controller.validateShuffleSelection(in: library)
            controller.validateAssignments(in: library)
        }
        .onChange(of: controller.isEnabled) { _, isEnabled in
            if !isEnabled { isSelectingShuffleItems = false }
        }
        .alert("Rename Wallpaper", isPresented: Binding(
            get: { itemToRename != nil },
            set: { if !$0 { itemToRename = nil } }
        )) {
            TextField("Name", text: $renamedName)
            Button("Cancel", role: .cancel) { itemToRename = nil }
            Button("Save") {
                if let itemToRename { library.rename(itemToRename, to: renamedName) }
                itemToRename = nil
            }
        }
        .alert(
            "Remove “\(itemToRemove?.name ?? "")” from Canvas?",
            isPresented: Binding(
                get: { itemToRemove != nil },
                set: { if !$0 { itemToRemove = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { itemToRemove = nil }
            Button("Remove", role: .destructive) {
                if let itemToRemove { library.remove(itemToRemove) }
                itemToRemove = nil
            }
        } message: {
            Text("Aster deletes its copy of this wallpaper. The file you imported it from is not changed.")
        }
    }

    private func beginRenaming(_ item: WallpaperItem) {
        renamedName = item.name
        itemToRename = item
    }
}

// MARK: - Backdrop and thumbnails

struct CanvasBackdrop: View {
    let item: WallpaperItem?

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                Color.clear
                if let item {
                    WallpaperThumbnail(item: item, maxPixel: 1_600, showsPlaceholder: false)
                    Color.black.opacity(0.57)
                    LinearGradient(
                        colors: [.black.opacity(0.18), Color.asterAccentDeep.opacity(0.13)],
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

/// Decodes small previews off the main thread and keeps them in memory, so the
/// library never loads full-resolution wallpapers while drawing or scrolling.
@MainActor
enum CanvasThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func cachedImage(for url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(for: url, maxPixel: maxPixel))
    }

    static func image(for item: WallpaperItem, url: URL, maxPixel: Int) async -> NSImage? {
        let key = key(for: url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key) { return cached }

        let rendered: CGImage?
        switch item.kind {
        case .image:
            rendered = await Task.detached(priority: .userInitiated) {
                downsampledImage(at: url, maxPixel: maxPixel)
            }.value
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            rendered = try? await generator.image(at: time).image
        }
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered, size: .zero)
        cache.setObject(image, forKey: key)
        return image
    }

    /// A downsampled preview of any image file, such as a saved clipboard image.
    static func image(forImageAt url: URL, maxPixel: Int) async -> NSImage? {
        let key = key(for: url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key) { return cached }
        let rendered = await Task.detached(priority: .userInitiated) {
            downsampledImage(at: url, maxPixel: maxPixel)
        }.value
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered, size: .zero)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func key(for url: URL, maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }

    nonisolated private static func downsampledImage(at url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct WallpaperThumbnail: View {
    @Environment(WallpaperLibrary.self) private var library
    let item: WallpaperItem
    var maxPixel = 640
    var showsPlaceholder = true
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                if showsPlaceholder { Color.black.opacity(0.25) }
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: max(viewport.size.width, 1), height: max(viewport.size.height, 1))
                        .clipped()
                } else if showsPlaceholder {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
        }
        .task(id: "\(item.filename)#\(maxPixel)") {
            let url = library.url(for: item)
            image = CanvasThumbnailCache.cachedImage(for: url, maxPixel: maxPixel)
            if image == nil {
                image = await CanvasThumbnailCache.image(for: item, url: url, maxPixel: maxPixel)
            }
        }
    }
}

/// Resolution, duration, and file size shown under a wallpaper's name.
private struct CanvasMediaInfo: Equatable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var fileSize: Int64?

    var summary: String {
        var parts: [String] = []
        if let pixelWidth, let pixelHeight { parts.append("\(pixelWidth) × \(pixelHeight)") }
        if let duration, duration.isFinite, duration > 0 {
            let seconds = Int(duration.rounded())
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        if let fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    static func load(for item: WallpaperItem, url: URL) async -> CanvasMediaInfo {
        var info = CanvasMediaInfo()
        info.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        switch item.kind {
        case .image:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                info.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
                info.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            }
        case .video:
            let asset = AVURLAsset(url: url)
            info.duration = (try? await asset.load(.duration))?.seconds
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                info.pixelWidth = Int(abs(size.width).rounded())
                info.pixelHeight = Int(abs(size.height).rounded())
            }
        }
        return info
    }
}

// MARK: - Library

private struct CanvasLibraryPanel: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Binding var showImporter: Bool
    @Binding var isSelectingShuffleItems: Bool
    let rename: (WallpaperItem) -> Void
    let remove: (WallpaperItem) -> Void
    @AppStorage("Aster.Canvas.thumbnailWidth") private var thumbnailWidth = 190.0

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            if isSelectingShuffleItems { shuffleSelectionBar }
            content
        }
        .padding(16)
        .glassPanel()
        .dropDestination(for: URL.self) { urls, _ in
            (try? library.importFiles(urls))?.isEmpty == false
        }
    }

    private var toolbar: some View {
        @Bindable var library = library
        return HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search wallpapers", text: $library.searchText)
                    .textFieldStyle(.plain)
                if !library.searchText.isEmpty {
                    Button { library.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Picker("Type", selection: $library.mediaFilter) {
                ForEach(WallpaperLibrary.MediaFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Sort", selection: $library.sortOrder) {
                ForEach(WallpaperLibrary.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            .help("Sort order")

            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3").font(.caption2)
                Slider(value: $thumbnailWidth, in: 140...300)
                    .controlSize(.mini)
                    .frame(width: 70)
                Image(systemName: "square.grid.2x2").font(.caption)
            }
            .foregroundStyle(.tertiary)
            .help("Thumbnail size")
        }
    }

    private var shuffleSelectionBar: some View {
        HStack(spacing: 12) {
            Label("Click wallpapers to add them to the shuffle", systemImage: "shuffle")
                .font(.subheadline.weight(.semibold))
            Text("\(controller.shuffleSelectionCount(in: library)) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { controller.selectAllForShuffle(in: library) }
            Button("Clear") { controller.clearShuffleSelection() }
                .disabled(controller.shuffleSelectionCount(in: library) == 0)
            Button("Done") { isSelectingShuffleItems = false }
                .fontWeight(.semibold)
                .foregroundStyle(Color.asterAccentLight)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.asterAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.asterAccent.opacity(0.4), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            ContentUnavailableView {
                Label("Make this Mac yours", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Add an image, GIF, or video — or drag files here. Looking for live wallpapers? Try one of these sites.")
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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailWidth), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(library.filteredItems) { item in
                        WallpaperCard(
                            item: item,
                            isSelectingShuffleItems: isSelectingShuffleItems,
                            rename: rename,
                            remove: remove
                        )
                    }
                }
                .padding(1)
            }
            HStack {
                Text(countSummary)
                Spacer()
                Text(isSelectingShuffleItems
                     ? "Click to add or remove"
                     : "Double-click to set as Desktop · right-click for more")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var countSummary: String {
        let total = library.items.count
        let shown = library.filteredItems.count
        let noun = total == 1 ? "wallpaper" : "wallpapers"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}

private struct CanvasWallpaperSourceLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.right.square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.asterAccentLight)
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
    let rename: (WallpaperItem) -> Void
    let remove: (WallpaperItem) -> Void

    private var isSelected: Bool { library.selectedID == item.id }
    private var isInShuffle: Bool { controller.isSelectedForShuffle(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WallpaperThumbnail(item: item)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .topLeading) { mediaBadge }
                .overlay(alignment: .topTrailing) { shuffleBadge }
                .overlay(alignment: .bottomTrailing) { destinationBadges }
            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .white.opacity(isSelected ? 0.11 : 0.04),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isSelected ? Color.asterAccent : .white.opacity(0.07), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            if isSelectingShuffleItems {
                controller.toggleShuffleSelection(item)
            } else {
                library.selectedID = item.id
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !isSelectingShuffleItems else { return }
            library.selectedID = item.id
            controller.apply(item, url: library.url(for: item))
        })
        .help(item.name)
        .contextMenu { menu }
    }

    private var mediaBadge: some View {
        Label(item.mediaLabel, systemImage: item.mediaSymbol)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.black.opacity(0.58), in: Capsule())
            .padding(7)
    }

    @ViewBuilder
    private var shuffleBadge: some View {
        if isSelectingShuffleItems {
            Image(systemName: isInShuffle ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isInShuffle ? Color.asterAccent : .black.opacity(0.35))
                .shadow(color: .black.opacity(0.4), radius: 3)
                .padding(7)
        } else if isInShuffle {
            Image(systemName: "shuffle")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.58), in: Circle())
                .padding(7)
                .help("In the wallpaper shuffle")
        }
    }

    private var destinationBadges: some View {
        HStack(spacing: 4) {
            ForEach(WallpaperController.CanvasDestination.allCases) { destination in
                if controller.isAssigned(item, to: destination) {
                    Image(systemName: destination.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.asterAccent.opacity(0.92), in: Circle())
                        .help("Current \(destination.rawValue)")
                }
            }
        }
        .padding(7)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Set as Desktop") { controller.apply(item, url: library.url(for: item)) }
        if NSScreen.screens.count > 1 {
            Menu("Set as Desktop On") {
                ForEach(AsterDisplay.connected) { display in
                    Button(display.name) {
                        controller.apply(item, url: library.url(for: item), displayKey: display.key)
                    }
                }
            }
        }
        Button("Set as Lock Screen") { controller.configureLockScreen(item, url: library.url(for: item)) }
            .disabled(!item.canUseAsLockScreenStill)
        Button("Set as Screen Saver") { controller.configureScreenSaver(item, url: library.url(for: item)) }
        Divider()
        Button(isInShuffle ? "Remove from Shuffle" : "Add to Shuffle") {
            controller.toggleShuffleSelection(item)
        }
        Divider()
        Button("Rename…") { rename(item) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([library.url(for: item)])
        }
        Divider()
        Button("Remove…", role: .destructive) { remove(item) }
    }
}

// MARK: - Inspector

private struct CanvasInspector: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case wallpaper = "Wallpaper"
        case shuffle = "Shuffle"
        case options = "Options"
        var id: String { rawValue }
    }

    @Binding var isSelectingShuffleItems: Bool
    let rename: (WallpaperItem) -> Void
    let remove: (WallpaperItem) -> Void
    @AppStorage("Aster.Canvas.inspectorTab") private var storedTab = Tab.wallpaper.rawValue

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: storedTab) ?? .wallpaper },
            set: { storedTab = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch tab.wrappedValue {
                    case .wallpaper:
                        CanvasWallpaperTab(rename: rename, remove: remove)
                    case .shuffle:
                        CanvasShuffleTab(isSelectingShuffleItems: $isSelectingShuffleItems)
                    case .options:
                        CanvasOptionsTab()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .glassPanel()
        .onChange(of: isSelectingShuffleItems) { _, isSelecting in
            if isSelecting { storedTab = Tab.shuffle.rawValue }
        }
    }
}

private struct CanvasWallpaperTab: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    let rename: (WallpaperItem) -> Void
    let remove: (WallpaperItem) -> Void
    @State private var mediaInfo: CanvasMediaInfo?
    @State private var displays = AsterDisplay.connected

    var body: some View {
        if let item = library.selectedItem {
            selection(item)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No wallpaper selected")
                    .font(.headline)
                Text("Add a wallpaper, then click it in the library to preview it and choose where it appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    }

    private func selection(_ item: WallpaperItem) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 14) {
            WallpaperThumbnail(item: item, maxPixel: 900)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(.white.opacity(0.09))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Button { rename(item) } label: {
                        Image(systemName: "pencil").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rename")
                }
                Text(metadata(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CanvasSection(title: "Use as", symbol: "rectangle.on.rectangle") {
                ForEach(WallpaperController.CanvasDestination.allCases) { destination in
                    destinationRow(destination, item: item)
                }
            }

            CanvasSection(title: "Fit", symbol: "aspectratio") {
                Picker("Fit", selection: $controller.fillMode) {
                    ForEach(WallpaperController.FillMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(fitHelp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CanvasToggleRow(
                title: "Include in shuffle",
                detail: "Rotate this wallpaper on every display.",
                isOn: Binding(
                    get: { controller.isSelectedForShuffle(item) },
                    set: { newValue in
                        if newValue != controller.isSelectedForShuffle(item) {
                            controller.toggleShuffleSelection(item)
                        }
                    }
                )
            )
            .padding(.horizontal, 12)

            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([library.url(for: item)]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Spacer()
                Button(role: .destructive) { remove(item) } label: {
                    Label("Remove…", systemImage: "trash")
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            CanvasStatusLine()
        }
        .task(id: item.filename) {
            mediaInfo = nil
            mediaInfo = await CanvasMediaInfo.load(for: item, url: library.url(for: item))
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            displays = AsterDisplay.connected
        }
    }

    private func metadata(for item: WallpaperItem) -> String {
        guard let summary = mediaInfo?.summary, !summary.isEmpty else { return item.mediaLabel }
        return "\(item.mediaLabel) · \(summary)"
    }

    private var fitHelp: String {
        switch controller.fillMode {
        case .fill: "Fills the screen and crops whatever doesn’t fit. Applies to Desktop and Screen Saver."
        case .fit: "Shows the whole wallpaper with black bars if needed. Applies to Desktop and Screen Saver."
        case .stretch: "Stretches to the screen’s shape. Applies to Desktop and Screen Saver."
        }
    }

    private func destinationRow(
        _ destination: WallpaperController.CanvasDestination,
        item: WallpaperItem
    ) -> some View {
        let isAssigned = controller.isAssigned(item, to: destination)
        let needsStill = destination == .lockScreen && !item.canUseAsLockScreenStill
        let isMotion = DesktopMedia(item).isMotion
        // A video that is chosen but not running, because resuming is off.
        let isIdle = destination == .desktop && isAssigned && isMotion
            && !controller.isPlayingOnDesktop(item)
        let isCurrent = isAssigned && !isIdle

        return HStack(spacing: 10) {
            Image(systemName: destination.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    Color.asterAccent.opacity(isCurrent ? 0.9 : 0.16),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Text(detail(for: destination, item: item, needsStill: needsStill))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            switch destination {
            case .desktop:
                desktopControl(item: item, isCurrent: isCurrent, isMotion: isMotion)
            case .lockScreen:
                if isCurrent {
                    currentLabel
                    Button { controller.clearLockScreen() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop using this on the Lock Screen")
                } else {
                    Button("Set") { controller.configureLockScreen(item, url: library.url(for: item)) }
                        .buttonStyle(CanvasPillButtonStyle(prominent: true))
                        .disabled(needsStill)
                }
            case .screenSaver:
                if isCurrent {
                    currentLabel
                } else {
                    Button("Set") { controller.configureScreenSaver(item, url: library.url(for: item)) }
                        .buttonStyle(CanvasPillButtonStyle(prominent: true))
                }
            }
        }
        .opacity(needsStill ? 0.55 : 1)
    }

    private var currentLabel: some View {
        Label("Current", systemImage: "checkmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.asterAccentLight)
    }

    private func detail(
        for destination: WallpaperController.CanvasDestination,
        item: WallpaperItem,
        needsStill: Bool
    ) -> String {
        if needsStill { return "Still images only" }
        guard destination == .desktop, displays.count > 1 else { return destination.detail }
        let keys = controller.desktopDisplayKeys(for: item)
        guard !keys.isEmpty, keys.count < displays.count else { return destination.detail }
        let names = displays.filter { keys.contains($0.key) }.map(\.name)
        return "On \(names.formatted(.list(type: .and)))"
    }

    @ViewBuilder
    private func desktopControl(item: WallpaperItem, isCurrent: Bool, isMotion: Bool) -> some View {
        let shownOn = controller.desktopDisplayKeys(for: item)
        let coversEveryDisplay = isCurrent && shownOn.count == displays.count
        if displays.count > 1, !coversEveryDisplay {
            // With several displays, choose where this wallpaper goes.
            Menu(isCurrent ? "Change" : (isMotion ? "Play" : "Set")) {
                Button("All Displays") { controller.apply(item, url: library.url(for: item)) }
                Divider()
                ForEach(displays) { display in
                    Button {
                        controller.apply(item, url: library.url(for: item), displayKey: display.key)
                    } label: {
                        if shownOn.contains(display.key) {
                            Label(display.name, systemImage: "checkmark")
                        } else {
                            Text(display.name)
                        }
                    }
                }
                if isCurrent, isMotion {
                    Divider()
                    Button("Stop") { controller.stopMotionWallpaper(item) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(controller.isApplying)
        } else if isCurrent, isMotion {
            Button("Stop") { controller.stopMotionWallpaper(item) }
                .buttonStyle(CanvasPillButtonStyle())
                .help("Stop this motion wallpaper")
        } else if isCurrent {
            currentLabel
        } else {
            Button(isMotion ? "Play" : "Set") {
                controller.apply(item, url: library.url(for: item))
            }
            .buttonStyle(CanvasPillButtonStyle(prominent: true))
            .disabled(controller.isApplying)
        }
    }
}

private struct CanvasShuffleTab: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperController.self) private var controller
    @Binding var isSelectingShuffleItems: Bool

    private var selectedCount: Int { controller.shuffleSelectionCount(in: library) }
    private var selectedItems: [WallpaperItem] {
        library.items.filter { controller.isSelectedForShuffle($0) }
    }

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.isShuffling ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text(controller.isShuffling ? "Shuffle is on" : "Shuffle is off")
                        .font(.headline)
                }
                statusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        if controller.isShuffling {
                            controller.stopShuffle()
                        } else {
                            controller.startShuffle(in: library)
                        }
                    } label: {
                        Label(
                            controller.isShuffling ? "Stop" : "Start Shuffle",
                            systemImage: controller.isShuffling ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AsterButtonStyle(prominent: !controller.isShuffling))
                    .disabled(!controller.isShuffling && selectedCount < 2)

                    if controller.isShuffling {
                        Button { controller.skipToNextShuffleItem() } label: {
                            Label("Next", systemImage: "forward.fill")
                        }
                        .buttonStyle(AsterButtonStyle(prominent: true))
                        .disabled(controller.isApplying)
                        .help("Change the wallpaper now")
                    }
                }
            }
            .padding(12)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            CanvasSection(title: "Schedule", symbol: "clock") {
                CanvasPickerRow(title: "Change every") {
                    Picker("Change every", selection: $controller.shuffleRate) {
                        ForEach(WallpaperController.ShuffleRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                }
                CanvasPickerRow(title: "Order") {
                    Picker("Order", selection: $controller.shuffleOrder) {
                        ForEach(WallpaperController.ShuffleOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                }
            }

            CanvasSection(title: "Wallpapers", symbol: "photo.stack") {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !selectedItems.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(selectedItems) { item in
                                WallpaperThumbnail(item: item, maxPixel: 320)
                                    .frame(width: 64, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .onTapGesture { library.selectedID = item.id }
                                    .help(item.name)
                            }
                        }
                    }
                    .frame(height: 40)
                }
                HStack(spacing: 8) {
                    Button(isSelectingShuffleItems ? "Done" : "Choose…") {
                        isSelectingShuffleItems.toggle()
                    }
                    .buttonStyle(CanvasPillButtonStyle(prominent: true))
                    Button("Select All") { controller.selectAllForShuffle(in: library) }
                        .buttonStyle(CanvasPillButtonStyle())
                        .disabled(library.items.isEmpty)
                    Button("Clear") { controller.clearShuffleSelection() }
                        .buttonStyle(CanvasPillButtonStyle())
                        .disabled(selectedCount == 0)
                }
                Text("Stills, GIFs, and videos can all be part of the shuffle. Shuffle resumes when Aster opens.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CanvasStatusLine()
        }
    }

    private var statusText: Text {
        if controller.isShuffling, let next = controller.nextShuffleDate {
            return Text("Changes every \(controller.shuffleRate.label). Next change in \(Text(next, style: .timer).monospacedDigit()).")
        }
        if selectedCount < 2 {
            return Text("Choose at least two wallpapers below, then start the shuffle.")
        }
        return Text("Ready to change the Desktop every \(controller.shuffleRate.label).")
    }

    private var selectionSummary: String {
        let total = library.items.count
        return "\(selectedCount) of \(total) wallpaper\(total == 1 ? "" : "s") in the shuffle"
    }
}

private struct CanvasOptionsTab: View {
    @Environment(WallpaperController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 14) {
            CanvasSection(title: "Motion wallpapers", symbol: "play.rectangle") {
                CanvasToggleRow(
                    title: "Mute audio",
                    detail: "Silences videos on the Desktop and Screen Saver.",
                    isOn: $controller.muted
                )
                CanvasPickerRow(title: "Speed") {
                    Picker("Speed", selection: $controller.playbackSpeed) {
                        ForEach(WallpaperController.PlaybackSpeed.allCases) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Dim")
                        Spacer()
                        Text(controller.motionDimming < 0.01 ? "Off" : "\(Int((controller.motionDimming * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $controller.motionDimming,
                        in: 0...WallpaperController.maximumMotionDimming,
                        step: 0.05
                    )
                    Text("Darkens the video so desktop icons and widgets are easier to read.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CanvasToggleRow(
                    title: "Resume when Aster opens",
                    detail: "Aster must stay open while a motion wallpaper plays.",
                    isOn: $controller.autoResumeMotionWallpaper
                )
            }

            CanvasSection(title: "Smart Pause", symbol: "pause.circle") {
                CanvasToggleRow(
                    title: "When the desktop is covered",
                    detail: "Pauses each display while a full-screen app or windows hide it.",
                    isOn: $controller.pauseMotionForFullScreenApps
                )
                CanvasToggleRow(
                    title: "On battery power",
                    detail: "Plays only while this Mac is plugged in.",
                    isOn: $controller.pauseMotionOnBattery
                )
                CanvasToggleRow(
                    title: "In Low Power Mode",
                    isOn: $controller.pauseMotionInLowPowerMode
                )
                CanvasToggleRow(
                    title: "When the Mac is busy",
                    detail: "Pauses after sustained CPU load above the limit.",
                    isOn: $controller.pauseMotionForHighSystemLoad
                )
                if controller.pauseMotionForHighSystemLoad {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("CPU limit")
                            Spacer()
                            Text("\(Int(controller.highSystemLoadThreshold))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $controller.highSystemLoadThreshold, in: 50...95, step: 5)
                        Text("Resumes below \(max(Int(controller.highSystemLoadThreshold) - 10, 0))%.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Label(
                    controller.smartPauseStatusMessage,
                    systemImage: controller.isMotionWallpaperPaused
                        ? "pause.circle.fill"
                        : "gauge.with.dots.needle.33percent"
                )
                .font(.caption2)
                .foregroundStyle(controller.isMotionWallpaperPaused ? Color.asterAccentLight : Color.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
            }

            CanvasSection(title: "Screen Saver", symbol: "sparkles") {
                CanvasPickerRow(title: "Rotation") {
                    Picker("Rotation", selection: $controller.screenSaverRotationInterval) {
                        ForEach(WallpaperController.ScreenSaverRotationInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                }
                Text("Cycles through your whole Canvas library while the saver runs. Off keeps the wallpaper you set.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                CanvasPickerRow(title: "Pixel shift") {
                    Picker("Pixel shift", selection: $controller.screenSaverShiftInterval) {
                        ForEach(WallpaperController.ScreenSaverShiftInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                }
                Text("Nudges the picture now and then so bright details don’t rest on the same pixels.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.screenSaverIsInstalled {
                    Button("Open Screen Saver Settings…") { controller.openScreenSaverSettings() }
                        .buttonStyle(CanvasPillButtonStyle())
                } else {
                    Text("Set any wallpaper as the Screen Saver to install Aster’s saver.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(controller.screenSaverStatusMessage, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CanvasSection(title: "How the Lock Screen works", symbol: "lock") {
                Text("macOS only allows a still image on the Lock Screen. You see it when you lock the Mac yourself, close the lid, or wake it.")
                Text("If the Screen Saver is already running when the Mac locks on its own, the saver keeps playing instead.")
                Text("When the Lock Screen and Desktop use different stills, Aster draws the Desktop one itself, so it shows only while Aster is open.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Building blocks

private struct CanvasSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CanvasToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.asterAccent)
        }
    }
}

private struct CanvasPickerRow<Content: View>: View {
    let title: String
    @ViewBuilder let picker: () -> Content

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 6)
            picker()
                .labelsHidden()
                .fixedSize()
        }
    }
}

private struct CanvasStatusLine: View {
    @Environment(WallpaperController.self) private var controller

    var body: some View {
        Label(controller.statusMessage, systemImage: controller.isApplying ? "hourglass" : "info.circle")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }
}

private struct CanvasPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minWidth: 46, minHeight: 26)
            .background(
                prominent ? Color.asterAccent.opacity(0.75) : Color.white.opacity(0.10),
                in: Capsule()
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
