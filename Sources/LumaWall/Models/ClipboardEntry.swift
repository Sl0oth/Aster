import Foundation

struct ClipboardEntry: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case text
        case link
        case color
        case image

        var label: String {
            switch self {
            case .text: "Text"
            case .link: "Link"
            case .color: "Color"
            case .image: "Image"
            }
        }

        var symbol: String {
            switch self {
            case .text: "doc.text.fill"
            case .link: "link"
            case .color: "paintpalette.fill"
            case .image: "photo.fill"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let text: String
    let imageFilename: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let createdAt: Date
    let sourceApp: String?

    var displayText: String {
        kind == .image ? "Image \(imageWidth ?? 0) × \(imageHeight ?? 0)" : text
    }

    init(
        id: UUID = UUID(),
        kind: Kind? = nil,
        text: String,
        imageFilename: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        createdAt: Date = .now,
        sourceApp: String?
    ) {
        self.id = id
        self.kind = kind ?? Self.classify(text)
        self.text = text
        self.imageFilename = imageFilename
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.createdAt = createdAt
        self.sourceApp = sourceApp
    }

    static func image(
        id: UUID = UUID(),
        filename: String,
        width: Int,
        height: Int,
        sourceApp: String?
    ) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            kind: .image,
            text: "",
            imageFilename: filename,
            imageWidth: width,
            imageHeight: height,
            sourceApp: sourceApp
        )
    }

    private static func classify(_ text: String) -> Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(
            of: #"^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .color
        }
        if !trimmed.contains("\n"),
           let url = URL(string: trimmed),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .link
        }
        return .text
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFilename, imageWidth, imageHeight, createdAt, sourceApp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? Self.classify(text)
        imageFilename = try container.decodeIfPresent(String.self, forKey: .imageFilename)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
    }
}

struct ClipboardBoard: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var itemIDs: [UUID]

    init(id: UUID = UUID(), name: String, itemIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
    }
}
