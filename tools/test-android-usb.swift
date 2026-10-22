import Foundation

@MainActor
final class FakeADB {
    var snapshot = "pad device usb:1 model:Pad_7 transport_id:1\nother device usb:2 model:Nexus transport_id:2"
    var forwards: [String] = ["other tcp:10022 tcp:22"]
    var calls: [[String]] = []
    var nextPort = 41000
    var fail = false
    var afterStart: (() -> Void)?

    func run(_ args: [String]) async throws -> String {
        calls.append(args)
        if fail { throw NSError(domain: "fake", code: 1) }
        if args == ["devices", "-l"] { return snapshot }
        if args == ["forward", "--list"] { return forwards.joined(separator: "\n") }
        precondition(args.prefix(2) == ["-s", "pad"] || args.prefix(2) == ["-s", "other"])
        if args.contains("path") { return args[1] == "pad" ? "package:/data/app/receiver.apk" : "" }
        if args.contains("tcp:0") {
            nextPort += 1
            forwards.append("pad tcp:\(nextPort) tcp:9000")
            return "\(nextPort)\n"
        }
        if args.contains("--remove") {
            forwards.removeAll { $0 == "pad \(args.last!) tcp:9000" }
        }
        if args.contains("start") { afterStart?() }
        return ""
    }
}

@main
struct AndroidUSBChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
            print("PASS \(message)")
        }
        let parsed = AndroidUSBDevice.parse("""
        List of devices attached
        * daemon started successfully
        pad device usb:1 model:Xiaomi_Pad transport_id:123
        locked unauthorized usb:2 transport_id:124
        192.168.1.2:5555 device model:Wireless transport_id:125
        emulator-5554 device transport_id:126
        adb-serial-random._adb-tls-connect._tcp device transport_id:127
        """)
        check(parsed.map(\.id) == ["pad", "locked"], "USB parsing excludes network ADB, emulator and daemon output")
        check(parsed[0].name == "Xiaomi Pad" && parsed[0].transportID == "123", "device model and transport identity")
        let domain = "OpenDisplayUSBTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let adb = FakeADB()
        let usb = AndroidUSB(defaults: defaults, command: adb.run)
        var ready: [(String, UInt16)] = []
        var unavailable: [String] = []
        usb.onReady = { ready.append(($0, $1)) }
        usb.onUnavailable = { unavailable.append($0) }
        await usb.pollOnce()
        check(ready.count == 1 && ready[0].0 == "pad", "only a compatible receiver auto-connects")
        check(usb.devices.count == 1 && usb.devices[0].port == 41001, "allocated port is exposed to sender")
        check(!adb.calls.contains { $0.prefix(2) == ["-s", "other"] && ($0.contains("start") || $0.contains("forward")) }, "unrelated device is never started or forwarded")
        await usb.pollOnce()
        check(ready.count == 1 && adb.calls.filter { $0.contains("start") }.count == 1, "stable polling doesn't reconnect or reopen the receiver")
        adb.forwards = ["other tcp:10022 tcp:22"]
        await usb.pollOnce()
        check(ready.count == 2 && ready.last!.1 == 41002, "lost ADB mapping repairs without a device-list change")
        adb.snapshot = "other device usb:2 model:Nexus transport_id:2"
        adb.forwards = ["other tcp:10022 tcp:22"]
        await usb.pollOnce()
        check(unavailable == ["pad"] && usb.devices[0].state == "disconnected", "unplug releases session and leaves a reconnect row")
        adb.snapshot = "pad device usb:1 model:Pad_7 transport_id:3"
        await usb.pollOnce()
        check(ready.count == 3, "replug with a new transport restores forwarding and connects")
        adb.snapshot = "pad device usb:1 model:Pad_7 transport_id:4"
        await usb.pollOnce()
        check(ready.count == 4 && unavailable.count == 3, "fast replug detected even without an offline snapshot")
        usb.pause("pad")
        await usb.pollOnce()
        check(ready.count == 4 && usb.isPaused("pad"), "explicit disconnect suppresses automatic reconnect")
        let restored = AndroidUSB(defaults: defaults, command: adb.run)
        await restored.pollOnce()
        check(restored.isPaused("pad") && restored.devices[0].port == nil, "disconnect choice survives application restart")
        usb.retry("pad")
        await usb.pollOnce()
        check(ready.count == 5 && !usb.isPaused("pad"), "Connect resumes after an explicit disconnect")
        adb.snapshot = "pad unauthorized usb:1 transport_id:4"
        await usb.pollOnce()
        check(usb.devices[0].message.contains("允许") && ready.count == 5, "unauthorized USB prompts for tablet authorization")
        adb.fail = true
        await usb.pollOnce()
        check(usb.issue != nil, "ADB failure is surfaced")
        adb.fail = false
        adb.snapshot = "pad device usb:1 model:Pad_7 transport_id:5"
        await usb.pollOnce()
        check(usb.issue == nil && ready.count == 6, "ADB failure recovers on the next successful scan")
        await usb.shutdown()
        check(adb.forwards == ["other tcp:10022 tcp:22"], "shutdown removes only this instance's forwards")
        defaults.set(false, forKey: "autostart")
        let manual = AndroidUSB(defaults: defaults, command: adb.run)
        var manualCount = 0
        manual.onReady = { _, _ in manualCount += 1 }
        await manual.pollOnce()
        check(manualCount == 0, "autostart NO is respected")
        manual.retry("pad")
        adb.afterStart = { manual.pause("pad") }
        await manual.pollOnce()
        check(manualCount == 0, "Disconnect during async setup cannot resurrect a session")
        adb.afterStart = nil
        manual.retry("pad")
        await manual.pollOnce()
        check(manualCount == 1, "manual Connect works with autostart disabled")
        await manual.shutdown()
        let output = try await AndroidUSB.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["hello"])
        check(output == "hello", "real subprocess output is returned")
        let start = Date()
        do {
            _ = try await AndroidUSB.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            preconditionFailure("timeout must throw")
        } catch { check(Date().timeIntervalSince(start) < 3, "hung command is terminated within its timeout") }
        print("\(count) Android USB checks passed")
    }
}
