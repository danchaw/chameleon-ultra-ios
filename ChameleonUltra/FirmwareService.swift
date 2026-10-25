import Foundation

/// A firmware package from the official RfidResearchGroup/ChameleonUltra
/// releases (asset names `ultra-dfu-app.zip` / `lite-dfu-app.zip`).
struct FirmwareRelease: Identifiable {
    let id = UUID()
    let tagName: String
    let name: String
    let body: String
    let zipURL: URL
    let isPrerelease: Bool

    var versionParts: (major: Int, minor: Int, patch: Int) {
        let cleaned = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        return (parts.count > 0 ? parts[0] : 0,
                parts.count > 1 ? parts[1] : 0,
                parts.count > 2 ? parts[2] : 0)
    }

    var versionString: String {
        let v = versionParts
        return "\(v.major).\(v.minor).\(v.patch)"
    }

    var shortNotes: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
    }
}

/// Checks GitHub releases for new device firmware and downloads the package.
@MainActor
final class FirmwareService: ObservableObject {

    @Published var checking = false
    @Published var latest: FirmwareRelease?
    @Published var checkError: String?

    static let releaseListURL = URL(string: "https://api.github.com/repos/RfidResearchGroup/ChameleonUltra/releases?per_page=10")!

    func checkForUpdates(device: ChameleonDevice) async {
        checking = true
        checkError = nil
        latest = nil
        defer { checking = false }

        do {
            let assetName = (device == .ultra ? "ultra" : "lite") + "-dfu-app.zip"
            var request = URLRequest(url: Self.releaseListURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                checkError = "Unexpected response from GitHub"
                return
            }

            // Prefer the newest stable release; fall back to the dev (prerelease) channel.
            for preferStable in [true, false] {
                for release in releases {
                    let prerelease = release["prerelease"] as? Bool ?? false
                    guard prerelease != preferStable else { continue }
                    guard let assets = release["assets"] as? [[String: Any]],
                          let asset = assets.first(where: { $0["name"] as? String == assetName }),
                          let urlString = asset["browser_download_url"] as? String,
                          let url = URL(string: urlString) else { continue }

                    latest = FirmwareRelease(
                        tagName: (release["tag_name"] as? String) ?? "",
                        name: (release["name"] as? String) ?? "",
                        body: (release["body"] as? String) ?? "",
                        zipURL: url,
                        isPrerelease: prerelease)
                    return
                }
            }
            checkError = "No firmware package found in releases"
        } catch {
            checkError = error.localizedDescription
        }
    }

    /// true when `latest` is newer than the device's firmware version
    /// (device reports major.minor packed as major<<8 | minor).
    func isUpdateAvailable(currentVersion: Int) -> Bool {
        guard let latest else { return false }
        let currentMajor = (currentVersion >> 8) & 0xFF
        let currentMinor = currentVersion & 0xFF
        let v = latest.versionParts
        if v.major != currentMajor { return v.major > currentMajor }
        if v.minor != currentMinor { return v.minor > currentMinor }
        return v.patch > 0
    }

    /// Download the firmware zip, reporting progress 0…1.
    func download(_ release: FirmwareRelease, progress: @escaping (Double) -> Void) async throws -> Data {
        progress(0)
        let (bytes, response) = try await URLSession.shared.bytes(from: release.zipURL)
        let total = Double(response.expectedContentLength)
        var result = Data()
        if total > 0 { result.reserveCapacity(Int(total)) }

        var chunk = [UInt8]()
        chunk.reserveCapacity(16384)
        var lastReported = 0.0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 16384 {
                result.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if total > 0 {
                    let fraction = Double(result.count) / total
                    if fraction - lastReported >= 0.02 || fraction >= 1 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
        }
        result.append(contentsOf: chunk)
        progress(1)
        return result
    }
}
