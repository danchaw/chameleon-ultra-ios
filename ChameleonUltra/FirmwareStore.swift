import Foundation

/// A firmware package previously downloaded by the app, kept on disk so it
/// can be re-flashed (or deleted) without downloading again.
struct FirmwarePackage: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String
    var title: String
    var sizeBytes: Int
    var downloadedAt: Date
}

/// Stores downloaded firmware zips under Documents/Firmware with a JSON index.
@MainActor
final class FirmwareStore: ObservableObject {

    @Published var packages: [FirmwarePackage] = []

    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firmware", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let list = try? JSONDecoder().decode([FirmwarePackage].self, from: data) else { return }
        // drop entries whose file disappeared
        packages = list.filter {
            FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent($0.fileName).path)
        }
    }

    private func persistIndex() {
        if let data = try? JSONEncoder().encode(packages) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    @discardableResult
    func save(zip: Data, title: String) -> FirmwarePackage {
        let fileName = "\(UUID().uuidString).zip"
        let url = Self.directory.appendingPathComponent(fileName)
        try? zip.write(to: url, options: .atomic)
        let package = FirmwarePackage(fileName: fileName, title: title,
                                      sizeBytes: zip.count, downloadedAt: Date())
        packages.insert(package, at: 0)
        persistIndex()
        return package
    }

    func data(for package: FirmwarePackage) -> Data? {
        try? Data(contentsOf: Self.directory.appendingPathComponent(package.fileName))
    }

    func delete(_ package: FirmwarePackage) {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(package.fileName))
        packages.removeAll { $0.id == package.id }
        persistIndex()
    }

    func deleteAll() {
        for package in packages {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(package.fileName))
        }
        packages = []
        persistIndex()
    }
}
