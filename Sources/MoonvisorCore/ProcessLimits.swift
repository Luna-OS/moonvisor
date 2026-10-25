import Darwin
import Foundation

/// Grenzen des QEMU-Prozesses.
///
/// macOS lehnt poll() mit mehr als 1024 Einträgen ab (EINVAL), sobald das Limit für offene Dateien darunter liegt.
/// Programme, die eine App startet, bekommen nur 256. Mit DirectX öffnen Store, Xbox-App und Spiele viele
/// Grafik-Verbindungen; dann scheitert jedes poll in QEMU, die Schleife dreht leer, schreibt „poll(2) failed due to:
/// Invalid argument“ ins Protokoll (zig MB), und die VM hängt.
public enum ProcessLimits {
    /// Mehr Einträge nimmt poll() auf macOS nie an (OPEN_MAX).
    static let pollMaximum: rlim_t = 10240

    /// Hebt das Limit für offene Dateien dieses Prozesses an; QEMU und swtpm erben es. Gibt das neue Limit zurück.
    @discardableResult
    public static func raiseOpenFileLimit() -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let kernel = sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0 && perProcess > 0
            ? rlim_t(perProcess) : pollMaximum
        for wanted in [min(limit.rlim_max, kernel), min(limit.rlim_max, pollMaximum)] where wanted > limit.rlim_cur {
            var raised = limit
            raised.rlim_cur = wanted
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { return wanted }
        }
        return limit.rlim_cur
    }

    /// Offene Dateien eines Prozesses; nil, wenn macOS sie nicht verrät.
    public static func openFileCount(pid: Int32) -> Int? {
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 1)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buffer, Int32(buffer.count * stride))
        return filled > 0 ? Int(filled) / stride : nil
    }
}
