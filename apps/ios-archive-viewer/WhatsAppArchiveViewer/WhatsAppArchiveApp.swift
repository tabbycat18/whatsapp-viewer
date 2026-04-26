import SwiftUI
import UniformTypeIdentifiers

enum ArchiveImportError: LocalizedError {
    case missingApplicationSupportDirectory
    case missingDatabase(URL)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Could not locate the app's Application Support folder."
        case .missingDatabase(let url):
            return "Missing ChatStorage.sqlite at \(url.path)"
        case .importFailed(let message):
            return "Could not import archive: \(message)"
        }
    }
}

@main
struct WhatsAppArchiveApp: App {
    @StateObject private var archiveStore = ArchiveStore()

    var body: some Scene {
        WindowGroup {
            ChatListView()
                .environmentObject(archiveStore)
        }
    }
}

@MainActor
final class ArchiveStore: ObservableObject {
    @Published var chats: [ChatSummary] = []
    @Published var selectedChat: ChatSummary?
    @Published var messages: [MessageRow] = []
    @Published var errorMessage: String?
    @Published var archiveName = "No Archive"

    let messageLimit = 500

    private let importedArchiveFolderName = "ImportedArchive"
    private var database: WhatsAppDatabase?
    private var didCheckDocumentsFolder = false

    func loadDefaultArchiveIfAvailable() {
        guard !didCheckDocumentsFolder, database == nil else { return }
        didCheckDocumentsFolder = true

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let databaseURL = documentsURL.appendingPathComponent("ChatStorage.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return
        }

        openDatabase(
            databaseURL: databaseURL,
            archiveRootURL: databaseURL.deletingLastPathComponent(),
            securityScopedURL: nil
        )
    }

    func openPickedURL(_ url: URL) {
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            database = nil
            let sourceArchiveRootURL = try archiveRootURL(for: url)
            let importedDatabaseURL = try importArchive(from: url)
            openDatabase(
                databaseURL: importedDatabaseURL,
                archiveRootURL: sourceArchiveRootURL,
                securityScopedURL: url
            )
        } catch {
            database = nil
            chats = []
            selectedChat = nil
            messages = []
            archiveName = "No Archive"
            errorMessage = error.localizedDescription
        }
    }

    func loadMessages(for chat: ChatSummary) {
        guard let database else { return }
        do {
            messages = try database.fetchMessages(chatID: chat.id, limit: messageLimit)
            errorMessage = nil
        } catch {
            messages = []
            errorMessage = error.localizedDescription
        }
    }

    private func openDatabase(databaseURL: URL, archiveRootURL: URL, securityScopedURL: URL?) {
        do {
            let openedDatabase = try WhatsAppDatabase(
                databaseURL: databaseURL,
                archiveRootURL: archiveRootURL,
                securityScopedURL: securityScopedURL
            )
            let loadedChats = try openedDatabase.fetchChats()
            database = openedDatabase
            chats = loadedChats
            selectedChat = loadedChats.first
            archiveName = databaseURL.deletingLastPathComponent().lastPathComponent
            errorMessage = nil

            if let firstChat = selectedChat {
                loadMessages(for: firstChat)
            } else {
                messages = []
            }
        } catch {
            database = nil
            chats = []
            selectedChat = nil
            messages = []
            archiveName = "No Archive"
            errorMessage = error.localizedDescription
        }
    }

    private func importArchive(from pickedURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let sourceDatabaseURL = try databaseURL(in: pickedURL)
        guard fileManager.fileExists(atPath: sourceDatabaseURL.path) else {
            throw ArchiveImportError.missingDatabase(sourceDatabaseURL)
        }

        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ArchiveImportError.missingApplicationSupportDirectory
        }

        let destinationFolderURL = applicationSupportURL.appendingPathComponent(
            importedArchiveFolderName,
            isDirectory: true
        )

        do {
            if fileManager.fileExists(atPath: destinationFolderURL.path) {
                try fileManager.removeItem(at: destinationFolderURL)
            }
            try fileManager.createDirectory(
                at: destinationFolderURL,
                withIntermediateDirectories: true
            )

            let destinationDatabaseURL = destinationFolderURL.appendingPathComponent("ChatStorage.sqlite")
            try fileManager.copyItem(at: sourceDatabaseURL, to: destinationDatabaseURL)

            for suffix in ["-wal", "-shm", "-journal"] {
                let sourceSidecarURL = URL(fileURLWithPath: sourceDatabaseURL.path + suffix)
                guard fileManager.fileExists(atPath: sourceSidecarURL.path) else { continue }
                let destinationSidecarURL = URL(fileURLWithPath: destinationDatabaseURL.path + suffix)
                try fileManager.copyItem(at: sourceSidecarURL, to: destinationSidecarURL)
            }

            return destinationDatabaseURL
        } catch {
            throw ArchiveImportError.importFailed(error.localizedDescription)
        }
    }

    private func databaseURL(in pickedURL: URL) throws -> URL {
        if try isDirectory(pickedURL) {
            return pickedURL.appendingPathComponent("ChatStorage.sqlite")
        }
        return pickedURL
    }

    private func archiveRootURL(for pickedURL: URL) throws -> URL {
        if try isDirectory(pickedURL) {
            return pickedURL
        }
        return pickedURL.deletingLastPathComponent()
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }
}
