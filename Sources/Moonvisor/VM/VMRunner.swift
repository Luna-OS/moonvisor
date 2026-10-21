import Foundation
import Virtualization

/// Owns the running `VZVirtualMachine` of one bundle.
@MainActor
final class VMRunner: NSObject, ObservableObject {
    let bundle: VMBundle
    @Published private(set) var state: VZVirtualMachine.State = .stopped
    @Published private(set) var machine: VZVirtualMachine?
    @Published private(set) var isLaunching = false
    @Published private(set) var isSuspended: Bool
    @Published private(set) var canSuspend = false
    @Published var lastError: String?
    private var stateObservation: NSKeyValueObservation?

    init(bundle: VMBundle) {
        self.bundle = bundle
        isSuspended = bundle.hasSavedState
        super.init()
    }

    var isActive: Bool { machine != nil || isLaunching }

    var statusText: String {
        if isLaunching && machine == nil { return "Starting…" }
        switch state {
        case .stopped: return isSuspended ? "Suspended" : "Stopped"
        case .running: return "Running"
        case .paused: return "Paused"
        case .error: return "Error"
        case .starting: return "Starting…"
        case .pausing: return "Pausing…"
        case .resuming: return "Resuming…"
        case .stopping: return "Stopping…"
        case .saving: return "Suspending…"
        case .restoring: return "Resuming…"
        @unknown default: return "Unknown"
        }
    }

    func start(with config: VMConfig) {
        guard !isActive else { return }
        isLaunching = true
        lastError = nil
        Task {
            defer { isLaunching = false }
            do {
                if isSuspended {
                    do {
                        let vm = try makeMachine(config)
                        try await vm.restoreStateAsync(from: bundle.savedStateURL)
                        try await vm.resumeAsync()
                        // The disk moves on from here, so the old state is no longer valid.
                        discardSavedState()
                        return
                    } catch {
                        teardown()
                        discardSavedState()
                        lastError = "The saved state couldn't be restored, so the machine started fresh. (\(error.localizedDescription))"
                    }
                }
                try await makeMachine(config).startAsync()
            } catch {
                teardown()
                lastError = error.localizedDescription
            }
        }
    }

    func pause() {
        Task {
            do { try await machine?.pauseAsync() } catch { lastError = error.localizedDescription }
        }
    }

    func resume() {
        Task {
            do { try await machine?.resumeAsync() } catch { lastError = error.localizedDescription }
        }
    }

    /// Asks the guest to shut down, like pressing the power button.
    func shutDown() {
        guard let vm = machine, vm.canRequestStop else { return }
        do { try vm.requestStop() } catch { lastError = error.localizedDescription }
    }

    /// Pulls the plug.
    func forceStop() async {
        guard let vm = machine else { return }
        do { try await vm.stopAsync() } catch { lastError = error.localizedDescription }
    }

    /// Saves the full machine state to disk and stops; the next start resumes it.
    func suspend() async {
        guard let vm = machine else { return }
        do {
            if vm.state == .running { try await vm.pauseAsync() }
            try await vm.saveStateAsync(to: bundle.savedStateURL)
            try await vm.stopAsync()
            isSuspended = true
        } catch {
            lastError = "Suspending failed: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            if vm.state == .paused { try? await vm.resumeAsync() }
        }
    }

    func discardSavedState() {
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        isSuspended = false
    }

    func refreshSuspendedState() {
        isSuspended = bundle.hasSavedState
    }

    /// Suspend if possible, otherwise shut down gracefully, force as a last resort.
    func stopForTermination() async {
        if canSuspend { await suspend() }
        if let vm = machine, vm.canRequestStop {
            try? vm.requestStop()
            for _ in 0..<60 where machine != nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await forceStop()
    }

    private func makeMachine(_ config: VMConfig) throws -> VZVirtualMachine {
        let configuration = try VMConfigurationBuilder.make(bundle: bundle, config: config)
        canSuspend = (try? configuration.validateSaveRestoreSupport()) != nil
        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        stateObservation = vm.observe(\.state, options: [.new]) { @Sendable [weak self] vm, _ in
            let newState = vm.state
            Task { @MainActor in self?.stateChanged(newState, of: vm) }
        }
        machine = vm
        return vm
    }

    private func stateChanged(_ newState: VZVirtualMachine.State, of vm: VZVirtualMachine) {
        guard vm === machine else { return }
        state = newState
        if newState == .stopped || newState == .error { teardown() }
    }

    private func teardown() {
        stateObservation = nil
        machine = nil
        state = .stopped
    }
}

extension VMRunner: VZVirtualMachineDelegate {
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }
}
