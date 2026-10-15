import AppKit
import Foundation

/// USB addresses change during a device reset; the helper identifies the port
/// instead. A brief disappearance must not cause another import in that session.
struct MTPConnectionTracker {
    private var attempted = Set<String>()
    private var missingSince: [String: Date] = [:]
    let disconnectGrace: TimeInterval

    var needsDisconnectConfirmation: Bool { !missingSince.isEmpty }

    init(disconnectGrace: TimeInterval = 8) {
        self.disconnectGrace = disconnectGrace
    }

    mutating func observe(_ connected: Set<String>, now: Date) -> [String] {
        for id in attempted.subtracting(connected) {
            let missing = missingSince[id] ?? now
            missingSince[id] = missing
            if now.timeIntervalSince(missing) >= disconnectGrace {
                attempted.remove(id)
                missingSince.removeValue(forKey: id)
            }
        }
        for id in connected {
            missingSince.removeValue(forKey: id)
        }
        let pending = connected.subtracting(attempted).sorted()
        attempted.formUnion(pending)
        return pending
    }
}

enum MTPHelperError: LocalizedError {
    case unavailable
    case timedOut
    case failed(Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Kindle sync is unavailable in this build. Please reinstall Leaf."
        case .timedOut:
            return "Kindle sync timed out. Close other transfer apps, then disconnect and reconnect your Kindle."
        case .invalidResponse:
            return "Leaf could not detect connected Kindles."
        case .failed(let code):
            switch code {
            case 2: return "Kindle was disconnected before sync finished."
            case 10: return "Could not connect to Kindle. Close other transfer apps, then disconnect and reconnect it."
            case 13: return "No My Clippings.txt was found in your Kindle's documents folder."
            case 17: return "Import failed: clippings file is larger than 20 MB."
            default: return "Could not sync Kindle. Disconnect and reconnect it, then try again."
            }
        }
    }
}

/// Called only on the watcher's utility queue. The child owns blocking USB work
/// and can be killed if the library stops responding, without blocking the UI.
struct MTPHelperProcess {
    let executableURL: URL
    var timeout: TimeInterval = 120

    static var bundled: MTPHelperProcess {
        MTPHelperProcess(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/LeafMTPHelper"))
    }

    func run(_ arguments: [String], captureOutput: Bool = false) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MTPHelperError.unavailable
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LIBMTP_DEBUG"] = "0"
        environment["LIBUSB_DEBUG"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = captureOutput ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw MTPHelperError.timedOut
        }
        if process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGALRM {
            throw MTPHelperError.timedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw MTPHelperError.failed(process.terminationStatus)
        }
        return captureOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    }

    func connectedDevices() throws -> Set<String> {
        let data = try run(["list"], captureOutput: true)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MTPHelperError.invalidResponse
        }
        var ids = Set<String>()
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("kindle:") else { throw MTPHelperError.invalidResponse }
            let id = String(line.dropFirst(7))
            guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 45 }) else {
                throw MTPHelperError.invalidResponse
            }
            ids.insert(id)
        }
        return ids
    }
}

final class MTPKindleWatcher {
    private let queue = DispatchQueue(label: "com.marcuslo.leaf.mtp", qos: .utility)
    private let helper: MTPHelperProcess
    private let syncDevice: (String) -> Void
    private let reportError: (String) -> Void
    private let prepare: () -> Void
    private var tracker = MTPConnectionTracker()
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var reportedScanFailure = false

    init(helper: MTPHelperProcess = .bundled,
         prepare: @escaping () -> Void = {},
         syncDevice: @escaping (String) -> Void,
         reportError: @escaping (String) -> Void) {
        self.helper = helper
        self.prepare = prepare
        self.syncDevice = syncDevice
        self.reportError = reportError
    }

    deinit {
        timer?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.prepare()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 12, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in self?.scan() }
            }
            timer.resume()
        }
    }

    private func scan(confirmDisconnects: Bool = true) {
        do {
            let connected = try helper.connectedDevices()
            reportedScanFailure = false
            let pending = tracker.observe(connected, now: Date())
            for id in pending { syncDevice(id) }
            // Confirm absence sooner than the next normal poll, while allowing
            // the known cleanup reset to finish. Failed scans never clear state.
            if confirmDisconnects && tracker.needsDisconnectConfirmation {
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.scan(confirmDisconnects: false) }
            }
        } catch {
            if !reportedScanFailure { reportError(error.localizedDescription) }
            reportedScanFailure = true
        }
    }
}
