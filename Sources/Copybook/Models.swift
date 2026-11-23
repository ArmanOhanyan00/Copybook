import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case text, link, image, color, file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .color: return "Color"
        case .file: return "File"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "doc.plaintext.fill"
        case .link: return "link"
        case .image: return "photo.fill"
        case .color: return "paintpalette.fill"
        case .file: return "folder.fill"
        }
    }

    var isTextual: Bool { self == .text || self == .link || self == .color }
}

struct ClipItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: ClipKind
    var date: Date = Date()
    var sourceBundleID: String?
    var sourceAppName: String?
    var text: String?
    var title: String?
    var filePaths: [String]?
    var imageWidth: Int?
    var imageHeight: Int?
    var linkTitle: String?
    var hasLinkImage: Bool = false
    var hasThumbnail: Bool = false
    var ocrText: String?
    /// Pasteboard type identifier → blob file name. Keys starting with "_" are internal (thumbnails etc).
    var representations: [String: String] = [:]
    var contentHash: String = ""

    var headerTitle: String {
        if let t = title, !t.isEmpty { return t }
        if kind == .file, let n = filePaths?.count, n > 1 { return "\(n) Files" }
        return kind.label
    }

    var hasRichText: Bool { representations["public.rtf"] != nil }

    var linkURL: URL? {
        guard kind == .link, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return URL(string: t)
    }

    func matches(_ tokens: [String]) -> Bool {
        var hay = [kind.label, sourceAppName ?? "", title ?? "", linkTitle ?? "", ocrText ?? ""]
        if let t = text { hay.append(String(t.prefix(20_000))) }
        if let f = filePaths { hay.append(contentsOf: f.map { ($0 as NSString).lastPathComponent }) }
        let joined = hay.joined(separator: " ").lowercased()
        return tokens.allSatisfy { joined.contains($0) }
    }
}
