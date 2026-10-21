import Foundation

/// Lädt die virtio-win-Treiber (enthalten ARM64-Treiber für Netzwerk, Grafik, Balloon, virtio-fs …).
public enum DriverStore {
    public static let virtioURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!

    public static var cacheFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvisor/Cache", isDirectory: true)
    }

    public static var virtioISOURL: URL { cacheFolder.appendingPathComponent("virtio-win.iso") }

    public static var cachedVirtioISO: URL? {
        FileManager.default.fileExists(atPath: virtioISOURL.path) ? virtioISOURL : nil
    }

    /// Lädt die Treiber-CD herunter, falls sie noch nicht im Cache liegt. `progress` meldet 0…1.
    public static func ensureVirtioISO(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let cached = cachedVirtioISO { return cached }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temp, response) = try await session.download(from: virtioURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MoonError.processFailed("Treiber-Download", "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try? FileManager.default.removeItem(at: virtioISOURL)
        try FileManager.default.moveItem(at: temp, to: virtioISOURL)
        return virtioISOURL
    }

    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
