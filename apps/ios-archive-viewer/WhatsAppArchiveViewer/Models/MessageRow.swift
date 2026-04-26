import Foundation

enum MediaAttachmentKind: String, Hashable {
    case photo
    case video
    case audio
    case media

    var placeholderText: String {
        switch self {
        case .photo:
            return "Photo attachment"
        case .video:
            return "Video attachment"
        case .audio:
            return "Audio attachment"
        case .media:
            return "Media attachment"
        }
    }
}

struct MediaMetadata: Hashable {
    let itemID: Int64?
    let localPath: String?
    let fileName: String?
    let title: String?
    let mimeType: String?
    let fileSize: Int64?
    let isFileAvailableInArchive: Bool
    let kind: MediaAttachmentKind
}

struct MessageRow: Identifiable, Hashable {
    let id: Int64
    let isFromMe: Bool
    let senderJID: String?
    let pushName: String?
    let text: String?
    let messageDate: Date?
    let messageType: Int?
    let media: MediaMetadata?
}
