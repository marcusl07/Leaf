import Foundation

struct MTPImportService {
    typealias ImportFile = (URL) -> ImportResult
    private let download: (String, URL) throws -> Void
    private let importFile: ImportFile
    private let root: URL
    private let fileManager: FileManager

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Leaf/MTPImports", isDirectory: true),
         fileManager: FileManager = .default,
         download: @escaping (String, URL) throws -> Void,
         importFile: @escaping ImportFile) {
        self.root = root
        self.fileManager = fileManager
        self.download = download
        self.importFile = importFile
    }

    func sync(_ connectionID: String) -> ImportResult {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("My Clippings.txt")
            try download(connectionID, file)
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else {
                throw MTPHelperError.invalidResponse
            }
            guard size.int64Value <= 20 * 1024 * 1024 else { throw MTPHelperError.failed(17) }
            return importFile(file)
        } catch {
            return ImportResult(newHighlightCount: 0, error: error.localizedDescription,
                                skippedEntryCount: 0, warningMessages: [], librarySnapshot: nil)
        }
    }

    func pruneStaleDownloads(now: Date = Date()) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }
}
