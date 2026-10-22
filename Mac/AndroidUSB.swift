import Foundation
import Combine

struct AndroidUSBDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var state: String
    var transportID: String?
    var message = "正在检查接收端…"
    var compatible = false
    var port: UInt16?

    /// Ignore wireless ADB and headers/daemon messages. Never grab a network device.
    static func parse(_ output: String) -> [Self] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2,
                  ["device", "offline", "unauthorized", "no"].contains(fields[1]),
                  !fields[0].hasPrefix("emulator-"),
                  !fields[0].contains(":"), !fields[0].hasPrefix("adb-") else { return nil }
            func field(_ prefix: String) -> String? {
                fields.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            }
            return Self(id: fields[0], name: field("model:")?.replacingOccurrences(of: "_", with: " ") ?? fields[0],
                        state: fields[1], transportID: field("transport_id:"))
        }
    }
}

/// ADB owns the USB transport; MacSender keeps using the existing TCP pipeline.
/// Polling also repairs a deleted forward when the device list hasn't changed.
@MainActor
final class AndroidUSB: ObservableObject {
    static let receiver = "io.github.josepacelli.opendisplay"
    @Published private(set) var devices: [AndroidUSBDevice] = []
    @Published private(set) var issue: String?
    var onReady: ((String, UInt16) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private let defaults: UserDefaults
    private let command: ([String]) async throws -> String
    private var task: Task<Void, Never>?
    private var installed: Set<String> = []
    private var checked: Set<String> = []
    private var ready: [String: UInt16] = [:]
    private var ports: [String: UInt16] = [:]
    private var paused: Set<String>
    // Invalidates an in-flight prepare when Disconnect/Retry is clicked.
    private var revision = 0
    private var manual: Set<String> = []

    static func adbURL(defaults: UserDefaults = .standard) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [defaults.string(forKey: "androidADBPath"),
                     "\(home)/.local/bin/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                     "\(home)/Library/Android/sdk/platform-tools/adb"]
        return paths.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    init(defaults: UserDefaults = .standard,
         command: (([String]) async throws -> String)? = nil) {
        self.defaults = defaults
        paused = Set(defaults.stringArray(forKey: "androidUSBPaused") ?? [])
        self.command = command ?? { args in
            guard let url = Self.adbURL(defaults: defaults) else {
                throw NSError(domain: "AndroidUSB", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "未找到 adb，请选择 Android platform-tools 中的 adb。"])
            }
            return try await Self.run(url, arguments: args)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    func isPaused(_ serial: String) -> Bool { paused.contains(serial) }

    func pause(_ serial: String) {
        revision += 1
        paused.insert(serial)
        ready.removeValue(forKey: serial)
        defaults.set(Array(paused), forKey: "androidUSBPaused")
    }

    func retry(_ serial: String) {
        revision += 1
        paused.remove(serial)
        manual.insert(serial)
        ready.removeValue(forKey: serial)
        defaults.set(Array(paused), forKey: "androidUSBPaused")
    }

    func refresh() { checked.removeAll() }

    func shutdown() async {
        let pending = task
        stop()
        revision += 1
        await pending?.value
        // Remove only forwards allocated by this instance and still owned by it.
        guard let output = try? await command(["forward", "--list"]) else { return }
        for (serial, port) in ports {
            if output.split(separator: "\n").contains(where: {
                $0.split(whereSeparator: \.isWhitespace).map(String.init)
                    == [serial, "tcp:\(port)", "tcp:9000"]
            }) {
                _ = try? await command(["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
        }
    }

    func pollOnce() async {
        let generation = revision
        do {
            let found = AndroidUSBDevice.parse(try await command(["devices", "-l"]))
            let forwards = try await command(["forward", "--list"])
            guard generation == revision, !Task.isCancelled else { return }
            let online = Set(found.filter { $0.state == "device" }.map(\.id))
            for serial in Array(ready.keys) where !online.contains(serial) {
                ready.removeValue(forKey: serial)
                onUnavailable?(serial)
            }
            var updated: [AndroidUSBDevice] = []
            for var device in found {
                let serial = device.id
                let old = devices.first { $0.id == serial }
                // A replug may be so quick that no offline snapshot was observed.
                if let old, old.transportID != device.transportID {
                    ready.removeValue(forKey: serial)
                    checked.remove(serial)
                    onUnavailable?(serial)
                }
                if device.state != "device" {
                    device.message = device.state == "unauthorized"
                        ? "请在平板上允许这台 Mac 进行 USB 调试" : "设备离线，请解锁平板或重新插线"
                    updated.append(device)
                    continue
                }
                if !checked.contains(serial) {
                    let result = (try? await command(["-s", serial, "shell", "pm", "path", Self.receiver])) ?? ""
                    guard generation == revision, !Task.isCancelled else { return }
                    checked.insert(serial)
                    if result.contains("package:") { installed.insert(serial) }
                    else { installed.remove(serial) }
                }
                device.compatible = installed.contains(serial)
                guard device.compatible else {
                    // Don't display/control unrelated phones that have no receiver.
                    continue
                }
                let automatic = defaults.object(forKey: "autostart") == nil || defaults.bool(forKey: "autostart")
                if paused.contains(serial) || (!automatic && !manual.contains(serial)) {
                    device.message = "已暂停自动连接，点击连接恢复"
                } else {
                    do {
                        let previousPort = ports[serial]
                        let mappingExists = previousPort.map { port in
                            forwards.split(separator: "\n").contains {
                                $0.split(whereSeparator: \.isWhitespace).map(String.init)
                                    == [serial, "tcp:\(port)", "tcp:9000"]
                            }
                        } ?? false
                        var port = previousPort
                        if !mappingExists {
                            // Allocate rather than steal an existing user's/device's port.
                            let output = try await command(["-s", serial, "forward", "tcp:0", "tcp:9000"])
                            guard let allocated = UInt16(output.trimmingCharacters(in: .whitespacesAndNewlines)), allocated > 0 else {
                                throw NSError(domain: "AndroidUSB", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: "ADB 未返回有效转发端口"])
                            }
                            port = allocated
                            ports[serial] = allocated
                        }
                        guard generation == revision, !Task.isCancelled else { return }
                        guard let port else { continue }
                        if ready[serial] != port {
                            _ = try await command(["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
                            guard generation == revision, !Task.isCancelled else { return }
                            _ = try await command(["-s", serial, "shell", "am", "start", "-n", "\(Self.receiver)/.MainActivity"])
                            guard generation == revision, !Task.isCancelled else { return }
                            ready[serial] = port
                            device.port = port
                            onReady?(serial, port)
                        }
                        device.port = port
                        device.message = "USB 已就绪 · 拔插后自动重连"
                    } catch {
                        if ready.removeValue(forKey: serial) != nil { onUnavailable?(serial) }
                        device.message = "连接失败：\(error.localizedDescription)"
                    }
                }
                updated.append(device)
            }
            guard generation == revision, !Task.isCancelled else { return }
            // Keep known receiver rows available during an unplug.
            for var old in devices where !found.contains(where: { $0.id == old.id }) && old.compatible {
                old.state = "disconnected"
                old.port = nil
                old.message = "USB 已断开 · 等待重新插入"
                updated.append(old)
            }
            if devices != updated { devices = updated }
            issue = nil
        } catch {
            issue = error.localizedDescription
            // Don't advertise a live path after ADB itself has failed.
            for serial in Array(ready.keys) { onUnavailable?(serial) }
            ready.removeAll()
        }
    }

    /// Execute off the UI thread, with a bounded lifetime. No shell interpolation
    /// and no global adb kill-server/reset (other devices may be in use).
    nonisolated static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 6) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(domain: "AndroidUSB", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   ? "ADB 命令超时或被中断，请检查 USB 连接" : output.trimmingCharacters(in: .whitespacesAndNewlines)]))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                    guard let process, process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak process] in
                        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
