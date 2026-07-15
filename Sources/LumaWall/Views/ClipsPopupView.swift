import AppKit
import SwiftUI

struct ClipsPopupView: View {
    @Environment(ClipboardManager.self) private var clipboard
    let onDismiss: @MainActor () -> Void

    @State private var activeBoardID: ClipboardBoard.ID?
    @State private var selectedEntryID: ClipboardEntry.ID?
    @State private var isAddingBoard = false
    @State private var newBoardName = ""
    @State private var boardToRename: ClipboardBoard?
    @State private var renamedBoardName = ""
    @State private var scrollSelectionIntoView = false
    @State private var navigationDirection = 0
    @State private var clipRowFrames: [ClipboardEntry.ID: CGRect] = [:]
    @State private var clipViewportHeight: CGFloat = 0
    @State private var dropTargetBoardID: ClipboardBoard.ID?
    @State private var recentlyDroppedBoardID: ClipboardBoard.ID?
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case search
        case newBoard
    }

    var body: some View {
        @Bindable var clipboard = clipboard
        let visibleEntries = clipboard.filteredEntries(in: activeBoardID)

        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.055),
                    Color.asterDeepPurple.opacity(0.08),
                    Color.black.opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                searchBar
                Divider().overlay(.white.opacity(0.055))

                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 170)

                    Divider().overlay(.white.opacity(0.055))

                    clipList(visibleEntries)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.045)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
        }
        .padding(10)
        .onAppear {
            selectedEntryID = visibleEntries.first?.id
            focusedField = .search
        }
        .onExitCommand(perform: onDismiss)
        .onChange(of: clipboard.boards) { _, boards in
            if let activeBoardID, !boards.contains(where: { $0.id == activeBoardID }) {
                self.activeBoardID = nil
            }
        }
        .onChange(of: visibleEntries.map(\.id)) { _, ids in
            if selectedEntryID.map({ !ids.contains($0) }) ?? true {
                selectedEntryID = ids.first
            }
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1, in: visibleEntries)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1, in: visibleEntries)
            return .handled
        }
        .alert("Rename Board", isPresented: Binding(
            get: { boardToRename != nil },
            set: { if !$0 { boardToRename = nil } }
        )) {
            TextField("Board name", text: $renamedBoardName)
            Button("Cancel", role: .cancel) { boardToRename = nil }
            Button("Save") {
                if let boardToRename {
                    clipboard.renameBoard(boardToRename.id, to: renamedBoardName)
                }
                boardToRename = nil
            }
        }
    }

    private var searchBar: some View {
        @Bindable var clipboard = clipboard
        return HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Find copied text, links, colors, or apps", text: $clipboard.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focusedField, equals: .search)
                .onSubmit(copySelected)

            if !clipboard.searchText.isEmpty {
                Button {
                    clipboard.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Text("⌘⇧V")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .frame(height: 23)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIBRARY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 13)
                .padding(.top, 16)
                .padding(.bottom, 7)

            sidebarRow(
                title: "All Clips",
                symbol: "clock.arrow.circlepath",
                count: clipboard.entries.count,
                isActive: activeBoardID == nil
            ) {
                activeBoardID = nil
            }

            HStack {
                Text("BOARDS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    isAddingBoard = true
                    focusedField = .newBoard
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(.white.opacity(0.055), in: Circle())
                .help("New board")
            }
            .padding(.leading, 13)
            .padding(.trailing, 10)
            .padding(.top, 17)
            .padding(.bottom, 6)

            if isAddingBoard {
                TextField("Board name", text: $newBoardName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($focusedField, equals: .newBoard)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 9)
                    .onSubmit(createBoard)
                    .onExitCommand {
                        newBoardName = ""
                        isAddingBoard = false
                        focusedField = .search
                    }
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(clipboard.boards) { board in
                        sidebarRow(
                            title: board.name,
                            symbol: recentlyDroppedBoardID == board.id ? "checkmark" : "square.stack.3d.up",
                            count: board.itemIDs.count,
                            isActive: activeBoardID == board.id,
                            isDropTarget: dropTargetBoardID == board.id
                        ) {
                            activeBoardID = board.id
                        }
                        .dropDestination(for: String.self) { transfers, _ in
                            accept(transfers, on: board.id)
                        } isTargeted: { isTargeted in
                            withAnimation(.easeOut(duration: 0.12)) {
                                if isTargeted {
                                    dropTargetBoardID = board.id
                                } else if dropTargetBoardID == board.id {
                                    dropTargetBoardID = nil
                                }
                            }
                        }
                        .contextMenu {
                            Button("Rename") {
                                renamedBoardName = board.name
                                boardToRename = board
                            }
                            Divider()
                            Button("Delete Board", role: .destructive) {
                                clipboard.deleteBoard(board.id)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 8)
            Divider().overlay(.white.opacity(0.045))

            HStack(spacing: 7) {
                Circle()
                    .fill(clipboard.isMonitoring ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                    .shadow(color: clipboard.isMonitoring ? .green.opacity(0.6) : .clear, radius: 4)
                Text(clipboard.isMonitoring ? "Capturing locally" : "Capture paused")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button(clipboard.isMonitoring ? "Pause Capture" : "Resume Capture") {
                        clipboard.isMonitoring.toggle()
                    }
                    Divider()
                    Button("Clear History", role: .destructive) {
                        clipboard.clearHistory()
                    }
                    .disabled(clipboard.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Clips options")
            }
            .padding(.horizontal, 12)
            .frame(height: 43)
        }
    }

    private func sidebarRow(
        title: String,
        symbol: String,
        count: Int,
        isActive: Bool,
        isDropTarget: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(isActive || isDropTarget ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                isDropTarget
                    ? Color.asterPurple.opacity(0.52)
                    : (isActive ? Color.asterPurple.opacity(0.32) : .clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isDropTarget ? Color.white.opacity(0.26) : .clear, lineWidth: 0.8)
            }
            .scaleEffect(isDropTarget ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func clipList(_ entries: [ClipboardEntry]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(activeBoardName)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(.white.opacity(0.045), in: Capsule())
                Spacer()
                Text("↑↓ select   ↩ copy")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .frame(height: 43)

            Divider().overlay(.white.opacity(0.045))

            if !clipboard.isMonitoring && clipboard.entries.isEmpty {
                emptyState(
                    symbol: "pause.circle",
                    title: "Clipboard capture is paused",
                    detail: "Aster keeps clips on this Mac and skips password managers.",
                    buttonTitle: "Resume Capture"
                ) {
                    clipboard.isMonitoring = true
                }
            } else if entries.isEmpty {
                emptyState(
                    symbol: clipboard.searchText.isEmpty ? "tray" : "magnifyingglass",
                    title: clipboard.searchText.isEmpty ? "No clips here" : "No results",
                    detail: emptyDescription,
                    buttonTitle: nil,
                    action: nil
                )
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: true) {
                            LazyVStack(spacing: 5) {
                                ForEach(entries) { entry in
                                    ClipsRecallRow(
                                        entry: entry,
                                        activeBoardID: activeBoardID,
                                        isSelected: selectedEntryID == entry.id
                                    ) {
                                        clipboard.copy(entry)
                                        onDismiss()
                                    }
                                    .id(entry.id)
                                    .background {
                                        GeometryReader { row in
                                            Color.clear.preference(
                                                key: ClipsRowFramesKey.self,
                                                value: [
                                                    entry.id: row.frame(in: .named(ClipsCoordinateSpace.viewport))
                                                ]
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(9)
                        }
                        .coordinateSpace(name: ClipsCoordinateSpace.viewport)
                        .onAppear { clipViewportHeight = viewport.size.height }
                        .onChange(of: viewport.size.height) { _, height in
                            clipViewportHeight = height
                        }
                        .onPreferenceChange(ClipsRowFramesKey.self) { frames in
                            clipRowFrames = frames
                        }
                        .onChange(of: selectedEntryID) { _, selectedID in
                            guard scrollSelectionIntoView, let selectedID else { return }
                            scrollSelectionIntoView = false
                            scrollToEdgeIfNeeded(selectedID, with: proxy)
                        }
                    }
                }
            }
        }
    }

    private func emptyState(
        symbol: String,
        title: String,
        detail: String,
        buttonTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.asterPurple.opacity(0.9))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.asterPurple)
                    .controlSize(.small)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeBoardName: String {
        guard let activeBoardID,
              let board = clipboard.boards.first(where: { $0.id == activeBoardID }) else {
            return "Recent"
        }
        return board.name
    }

    private var emptyDescription: String {
        if !clipboard.searchText.isEmpty { return "Try another word or app name." }
        if activeBoardID != nil { return "Add a clip here from its context menu." }
        return "Anything you copy will appear here."
    }

    private func createBoard() {
        if let board = clipboard.createBoard(named: newBoardName) {
            activeBoardID = board.id
        }
        newBoardName = ""
        isAddingBoard = false
        focusedField = .search
    }

    private func accept(
        _ transfers: [String],
        on boardID: ClipboardBoard.ID
    ) -> Bool {
        var accepted = false
        for transfer in transfers {
            guard let entryID = ClipsDragValue.entryID(from: transfer),
                  let entry = clipboard.entries.first(where: { $0.id == entryID }) else { continue }
            accepted = clipboard.add(entry, toBoard: boardID) || accepted
        }
        dropTargetBoardID = nil
        guard accepted else { return false }

        recentlyDroppedBoardID = boardID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            if recentlyDroppedBoardID == boardID {
                recentlyDroppedBoardID = nil
            }
        }
        return true
    }

    private func moveSelection(by offset: Int, in entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        scrollSelectionIntoView = true
        navigationDirection = offset
        guard let selectedEntryID,
              let currentIndex = entries.firstIndex(where: { $0.id == selectedEntryID }) else {
            self.selectedEntryID = entries.first?.id
            return
        }
        let nextIndex = min(max(currentIndex + offset, 0), entries.count - 1)
        self.selectedEntryID = entries[nextIndex].id
    }

    private func scrollToEdgeIfNeeded(_ id: ClipboardEntry.ID, with proxy: ScrollViewProxy) {
        let edgeInset: CGFloat = 76
        guard let frame = clipRowFrames[id] else {
            withAnimation(.easeOut(duration: 0.14)) {
                proxy.scrollTo(id, anchor: navigationDirection < 0 ? .top : .bottom)
            }
            return
        }

        let anchor: UnitPoint?
        if frame.minY < edgeInset {
            anchor = UnitPoint(x: 0.5, y: 0.16)
        } else if frame.maxY > clipViewportHeight - edgeInset {
            anchor = UnitPoint(x: 0.5, y: 0.84)
        } else {
            anchor = nil
        }
        guard let anchor else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private func copySelected() {
        let entries = clipboard.filteredEntries(in: activeBoardID)
        guard let selectedEntryID,
              let entry = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first else { return }
        clipboard.copy(entry)
        onDismiss()
    }
}

private struct ClipsRecallRow: View {
    @Environment(ClipboardManager.self) private var clipboard
    let entry: ClipboardEntry
    let activeBoardID: ClipboardBoard.ID?
    let isSelected: Bool
    let onCopy: @MainActor () -> Void
    @State private var isHovering = false

    var body: some View {
        row.draggable(
            ClipsDragValue.string(for: entry.id)
        ) {
            dragPreview
        }
        .contextMenu { contextMenu }
        .onHover { isHovering = $0 }
    }

    private var dragPreview: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(Color.asterPurple)
            Text(primaryText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(width: 260, height: 42, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.7)
        }
    }

    private var row: some View {
        Button(action: onCopy) {
            HStack(spacing: 12) {
                preview
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(primaryText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(entry.kind == .text ? 2 : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        Text(entry.sourceApp ?? "Unknown app")
                            .lineLimit(1)
                        Text("·")
                        Text(entry.createdAt, style: .relative)
                        Spacer(minLength: 6)
                        Text(entry.kind.label)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                }

                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .clear)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? Color.white.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 10)
            .frame(height: 68)
            .background(
                isSelected
                    ? Color.white.opacity(0.085)
                    : Color.white.opacity(isHovering ? 0.055 : 0.018),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.11) : .clear, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy and close")
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.kind {
        case .image:
            if let url = clipboard.imageURL(for: entry), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                previewSymbol("photo")
            }
        case .color:
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(parsedColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 0.7)
                }
        case .link:
            previewSymbol("link")
        case .text:
            previewSymbol("text.alignleft")
        }
    }

    private func previewSymbol(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(entry.kind == .link ? Color.blue : Color.asterPurple)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primaryText: String {
        switch entry.kind {
        case .image:
            return "Image · \(entry.imageWidth ?? 0) × \(entry.imageHeight ?? 0)"
        case .color, .link, .text:
            return entry.text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy") { onCopy() }
        if !clipboard.boards.isEmpty {
            Menu("Add to Board") {
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
        }
        Divider()
        Button(activeBoardID == nil ? "Delete" : "Remove from Board", role: .destructive) {
            clipboard.remove(entry, from: activeBoardID)
        }
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

private enum ClipsCoordinateSpace {
    static let viewport = "Aster.Clips.viewport"
}

private enum ClipsDragValue {
    private static let prefix = "aster-clip:"

    static func string(for entryID: ClipboardEntry.ID) -> String {
        prefix + entryID.uuidString
    }

    static func entryID(from string: String) -> ClipboardEntry.ID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

private struct ClipsRowFramesKey: PreferenceKey {
    static let defaultValue: [ClipboardEntry.ID: CGRect] = [:]

    static func reduce(
        value: inout [ClipboardEntry.ID: CGRect],
        nextValue: () -> [ClipboardEntry.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
