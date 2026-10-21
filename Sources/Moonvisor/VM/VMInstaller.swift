import Foundation
import Virtualization

/// Creates a new VM bundle and installs macOS into it from a restore image.
@MainActor
final class VMInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case fetchingCatalog
        case downloading(Double)
        case loadingImage
        case installing(Double)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private var downloader: RestoreImageDownloader?
    private var installProgress: Progress?
    private var progressObservation: NSKeyValueObservation?

    var isBusy: Bool {
        switch phase {
        case .fetchingCatalog, .downloading, .loadingImage, .installing: return true
        case .idle, .finished, .failed: return false
        }
    }

    func install(config: VMConfig, restoreImage: URL?, library: VMLibrary) {
        guard !isBusy else { return }
        task = Task {
            do {
                guard VZVirtualMachine.isSupported else { throw MoonvisorError.unsupportedHost }
                let imageURL: URL
                if let restoreImage {
                    imageURL = restoreImage
                } else {
                    imageURL = try await downloadLatest(into: library.restoreImagesDirectory)
                }
                try Task.checkCancellation()

                phase = .loadingImage
                let image = try await VZMacOSRestoreImage.loadAsync(from: imageURL)
                guard let requirements = image.mostFeaturefulSupportedConfiguration,
                      requirements.hardwareModel.isSupported
                else { throw MoonvisorError.noSupportedConfiguration(image.versionDescription) }

                var config = config
                config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
                let minimumGB = Int((requirements.minimumSupportedMemorySize + HostLimits.gib - 1) / HostLimits.gib)
                config.memoryGB = max(config.memoryGB, minimumGB)
                config.osVersion = image.versionDescription

                let bundle = VMBundle(url: library.newBundleURL(for: config.name))
                do {
                    try prepare(bundle, hardwareModel: requirements.hardwareModel, diskGB: config.diskGB)
                    let vm = VZVirtualMachine(configuration: try VMConfigurationBuilder.make(bundle: bundle, config: config))
                    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
                    phase = .installing(0)
                    installProgress = installer.progress
                    progressObservation = installer.progress.observe(\.fractionCompleted) { @Sendable progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor [weak self] in
                            guard let self, case .installing = self.phase else { return }
                            self.phase = .installing(fraction)
                        }
                    }
                    defer {
                        progressObservation = nil
                        installProgress = nil
                    }
                    try await installer.installAsync()
                    // Written last: a bundle without config.json is ignored by the library.
                    try bundle.save(config)
                } catch {
                    try? FileManager.default.removeItem(at: bundle.url)
                    throw error
                }
                library.reload()
                phase = .finished(bundle.url)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        downloader?.cancel()
        installProgress?.cancel()
        task?.cancel()
    }

    private func downloadLatest(into directory: URL) async throws -> URL {
        phase = .fetchingCatalog
        let latest = try await VZMacOSRestoreImage.latestSupportedAsync()
        let destination = directory.appendingPathComponent(latest.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        phase = .downloading(0)
        let downloader = RestoreImageDownloader(destination: destination) { @Sendable fraction in
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
            }
        }
        self.downloader = downloader
        defer { self.downloader = nil }
        return try await downloader.download(latest.url)
    }

    private func prepare(_ bundle: VMBundle, hardwareModel: VZMacHardwareModel, diskGB: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.url, withIntermediateDirectories: false)
        try hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: hardwareModel)

        // Sparse file: takes no space until the guest writes to it.
        guard fm.createFile(atPath: bundle.diskURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: bundle.diskURL.path])
        }
        let handle = try FileHandle(forWritingTo: bundle.diskURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(diskGB) * HostLimits.gib)
    }
}

/// Downloads a restore image (~15 GB) with progress. The file only appears
/// at `destination` once complete, so an interrupted download is never reused.
final class RestoreImageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session
                task = session.downloadTask(with: url)
                task?.resume()
            }
        }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(MoonvisorError.downloadFailed(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
