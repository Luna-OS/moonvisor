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

    /// Gasttools von UTM mit dem signierten DirectX-Treiber Triton (viogpu3d, ARM64) für den DirectX-Modus.
    public static let directXDriversURL = URL(string: "https://getutm.app/downloads/utm-guest-tools-3d-latest.iso")!
    public static var directXISOURL: URL { cacheFolder.appendingPathComponent("directx-drivers.iso") }

    public static var cachedDirectXISO: URL? {
        FileManager.default.fileExists(atPath: directXISOURL.path) ? directXISOURL : nil
    }

    /// Lädt die DirectX-Treiber-CD, falls sie noch nicht im Cache liegt. `progress` meldet 0…1.
    public static func ensureDirectXISO(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let cached = cachedDirectXISO { return cached }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        // Erst vollständig laden, dann umbenennen: ein abgebrochener Download zählt nicht als vorhanden.
        let partial = cacheFolder.appendingPathComponent("directx-drivers.iso.part")
        _ = try await download(from: directXDriversURL, to: partial, label: "DirectX-Treiber", progress: progress)
        try? FileManager.default.removeItem(at: directXISOURL)
        try FileManager.default.moveItem(at: partial, to: directXISOURL)
        return directXISOURL
    }

    /// Lädt die Treiber-CD herunter, falls sie noch nicht im Cache liegt. `progress` meldet 0…1.
    public static func ensureVirtioISO(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let cached = cachedVirtioISO { return cached }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        return try await download(to: virtioISOURL, progress: progress)
    }

    public static func download(from source: URL = virtioURL, to destination: URL, label: String = "Treiber-Download",
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // Klassischer Download-Task statt `session.download(from:)`: nur so ruft URLSession den
        // Fortschritts-Delegate auf.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = DownloadDelegate(destination: destination, label: label, progress: progress) { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: source).resume()
            session.finishTasksAndInvalidate()
        }
    }

    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let label: String
        let progress: @Sendable (Double) -> Void
        private var completion: ((Result<URL, Error>) -> Void)?
        private var moveError: Error?

        init(destination: URL, label: String, progress: @escaping @Sendable (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
            self.destination = destination
            self.label = label
            self.progress = progress
            self.completion = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        /// Die temporäre Datei existiert nur während dieses Aufrufs – daher hier verschieben.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                moveError = MoonError.processFailed(label, "HTTP \(status)")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<URL, Error>
            if let error = error ?? moveError {
                result = .failure(error)
            } else {
                result = .success(destination)
            }
            completion?(result)
            completion = nil
        }

        /// fedorapeople.org leitet auf `http://` um. Apps dürfen unverschlüsseltes HTTP nicht laden
        /// (App Transport Security) – und Treiber sollen ohnehin nur verschlüsselt kommen.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(DriverStore.secureRedirect(request))
        }
    }

    static func secureRedirect(_ request: URLRequest) -> URLRequest {
        guard let url = request.url, url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return request }
        components.scheme = "https"
        var secure = request
        secure.url = components.url
        return secure
    }

    /// Übersetzt Netzwerkfehler in verständliche Hinweise.
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Keine Internetverbindung. Die Windows-Treiber (ca. 850 MB) werden einmalig heruntergeladen."
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "Der Treiber-Server (fedorapeople.org) ist gerade nicht erreichbar. Bitte später erneut versuchen."
        default:
            return "Die Windows-Treiber konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }
}
