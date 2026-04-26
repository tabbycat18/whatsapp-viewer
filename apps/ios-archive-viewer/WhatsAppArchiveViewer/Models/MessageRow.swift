import Foundation

struct MessageRow: Identifiable, Hashable {
    let id: Int64
    let isFromMe: Bool
    let senderJID: String?
    let pushName: String?
    let text: String?
    let messageDate: Date?
}
