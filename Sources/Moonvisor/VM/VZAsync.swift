import Virtualization

// Virtualization objects must be used on the queue they were created on
// (the main queue here), so these wrappers stay on the main actor instead of
// relying on the imported async variants.

@MainActor
extension VZVirtualMachine {
    func startAsync() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            start { c.resume(with: $0) }
        }
    }

    func pauseAsync() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pause { c.resume(with: $0) }
        }
    }

    func resumeAsync() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            resume { c.resume(with: $0) }
        }
    }

    func stopAsync() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            stop { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func saveStateAsync(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            saveMachineStateTo(url: url) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func restoreStateAsync(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            restoreMachineStateFrom(url: url) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}

@MainActor
extension VZMacOSInstaller {
    func installAsync() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            install { c.resume(with: $0) }
        }
    }
}

extension VZMacOSRestoreImage {
    static func latestSupportedAsync() async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { c in
            fetchLatestSupported { c.resume(with: $0) }
        }
    }

    static func loadAsync(from url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { c in
            load(from: url) { c.resume(with: $0) }
        }
    }

    var versionDescription: String {
        let v = operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(buildVersion))"
    }
}
