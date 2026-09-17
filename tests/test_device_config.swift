import Foundation

// DeviceConfigModel does not need a radio in host tests. This snapshot is the
// small boundary normally supplied by BLERelay; the tested code is the actual
// settings model and status parser.
struct CompanionAuthSnapshot {
    struct TrustedCompanion: Identifiable {
        var id: String
        var name: String
        var platformName: String { "Test" }
    }
    var state = "authorized"
    var statusText = "Test"
    var deviceID = "test-device"
    var alias = ""
    var currentID = "test-companion"
    var currentName = "我的 Mac"
    var trusted: [TrustedCompanion] = []
    var reason = ""
}

private var capturedLogs: [String] = []
func log(_ message: String) { capturedLogs.append(message) }

@main
struct TestDeviceConfig {
    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
    }

    private static func drainCallbacks() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    static func main() {
        let suiteName = "test.device-config." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        var sent: [[(String, String)]] = []
        let model = DeviceConfigModel(sender: { pairs, complete in
            sent.append(pairs)
            complete(true)
        }, deviceKey: "A", defaults: defaults, enableDebugChannel: false)
        model.isConnected = true

        expect(!model.bootChimeEnabled, "boot music defaults to off")
        expect(model.bootChimeVolume == 20, "boot music has its own 20 percent default")
        expect(!model.bootChimeLoaded, "default music state is not treated as a device reading")
        model.pushBootChimeSettings()
        expect(sent.isEmpty, "music settings cannot save before the device snapshot")
        model.pushDeviceSettings()
        expect(sent.last?.contains { $0.0.hasPrefix("boot_chime.") } == false,
               "general settings cannot overwrite the device music settings")
        drainCallbacks()
        expect(model.settingsSaving && model.statusText != "已保存到设备",
               "transport acceptance does not claim settings were persisted")
        model.applyDeviceStatus([("volume", "60"), ("brightness", "100"),
                                 ("sb.items", "battery,ble,wifi,time")])
        expect(!model.settingsSaving && model.statusText == "已保存到设备",
               "matching device snapshot confirms settings")
        model.applyDeviceStatus([("boot_chime.enabled", "1")])
        expect(model.bootChimeEnabled && !model.bootChimeLoaded,
               "music settings wait for both enabled and volume")
        let countBeforePartialSave = sent.count
        model.pushBootChimeSettings()
        expect(sent.count == countBeforePartialSave, "partial music snapshot cannot overwrite default volume")
        model.applyDeviceStatus([("boot_chime.volume", "101")])
        expect(!model.bootChimeLoaded && model.bootChimeVolume == 20, "invalid volume is not a valid snapshot")
        model.applyDeviceStatus([("boot_chime.volume", "20")])
        expect(model.bootChimeLoaded, "music settings become ready after both fields are read")
        model.bootChimeEnabled = false
        model.pushBootChimeSettings()
        expect(sent.last?.contains { $0.0 == "boot_chime.enabled" && $0.1 == "0" } == true,
               "saving settings writes music off")
        expect(sent.last?.map { $0.0 } == ["boot_chime.enabled", "boot_chime.volume"],
               "music page saves only its own switch and volume")
        drainCallbacks()
        model.applyDeviceStatus([("boot_chime.enabled", "1")])
        expect(model.settingsSaving, "an old device value cannot confirm the requested music change")
        model.applyDeviceStatus([("boot_chime.enabled", "0")])
        expect(!model.settingsSaving && !model.bootChimeEnabled, "device confirms music off")
        model.bootChimeEnabled = true
        model.pushBootChimeSettings()
        expect(sent.last?.contains { $0.0 == "boot_chime.enabled" && $0.1 == "1" } == true,
               "saving settings writes music on")
        model.applyDeviceStatus([("boot_chime.enabled", "1")])
        drainCallbacks()
        expect(model.statusText == "已保存到设备",
               "late transport callback does not overwrite device confirmation")
        model.volume = 0
        model.bootChimeVolume = 100
        model.pushBootChimeSettings()
        expect(sent.last?.contains { $0.0 == "boot_chime.volume" && $0.1 == "100" } == true,
               "music volume remains independent when playback volume is zero")
        model.applyDeviceStatus([("boot_chime.enabled", "1")])
        expect(model.settingsSaving, "switch-only snapshot cannot confirm a new music volume")
        model.applyDeviceStatus([("boot_chime.volume", "100")])
        expect(!model.settingsSaving && model.bootChimeVolume == 100 && model.volume == 0,
               "device confirms music volume without changing playback volume")
        model.bootChimeVolume = 0
        model.pushBootChimeSettings()
        expect(sent.last?.contains { $0.0 == "boot_chime.volume" && $0.1 == "0" } == true,
               "music volume zero can be saved for silence")
        model.applyDeviceStatus([("boot_chime.volume", "0")])
        model.pushDeviceSettings()
        expect(sent.last?.contains { $0.0.hasPrefix("boot_chime.") } == false,
               "general save remains separate after music settings are loaded")
        model.applyDeviceStatus(sent.last!)
        drainCallbacks()
        sent.removeAll()

        model.applyDeviceStatus([("wifi.password_required", "1"), ("wifi.selected", "Device AP")])
        expect(model.selectedSSID == "Device AP" && model.selectedRequiresPassword,
               "device selection is independent of field order")
        expect(model.selectedOnDevice && model.wifiSetupRequest != nil,
               "encrypted device selection requests the Wi-Fi settings page")
        let request = model.wifiSetupRequest
        model.wifiPassword = "test-input-only"
        model.applyDeviceStatus([("wifi.selected", "Device AP"), ("wifi.password_required", "1")])
        expect(model.wifiPassword == "test-input-only" && model.wifiSetupRequest == request,
               "repeated status neither erases typing nor reopens navigation")
        model.applyDeviceStatus([("wifi.selected", "Second AP")])
        expect(model.selectedSSID == "Second AP" && model.wifiPassword.isEmpty,
               "changing device selection clears the previous password")
        model.applyDeviceStatus([("wifi.selected", ""), ("wifi.password_required", "0")])
        expect(!model.selectedOnDevice && model.wifiSetupRequest == nil,
               "clearing the device request releases navigation")

        model.applyDeviceStatus([("wifi.ap", "Unframed\t-1\t1")])
        expect(model.scanResults.isEmpty, "unframed scan rows are ignored")
        model.applyDeviceStatus([("wifi.ap.begin", "1"), ("wifi.ap", "Far\t-70\t1")])
        expect(model.scanResults.isEmpty, "scan stays atomic until end marker")
        model.applyDeviceStatus([
            ("wifi.ap", "Near\t-40\t0"), ("wifi.ap", "Far\t-60\t1"),
            ("wifi.ap", "Invalid\tnan\t1"), ("wifi.ap", "Broken\t-1\t9"),
            ("wifi.ap", "Tab\tSSID\t-20\t1"), ("wifi.ap.end", "1")
        ])
        expect(model.scanResults.count == 2 && model.scanResults.first?.ssid == "Near",
               "real scan rows are validated, deduplicated and sorted by signal")
        expect(model.scanResults.last?.rssi == -60, "duplicate SSID keeps strongest signal")
        expect(model.wifiScanStatus == "ready" && !model.wifiScanning,
               "completed scan has a terminal state")
        model.applyDeviceStatus([("wifi.ap.begin", "1"), ("wifi.ap", "Same name\t-45\t0"),
                                 ("wifi.ap", "Same name\t-40\t1"), ("wifi.ap.end", "2")])
        expect(model.scanResults.count == 2 && model.scanResults[0].id != model.scanResults[1].id,
               "open and secured networks sharing an SSID remain separate")
        model.selectNetwork(model.scanResults[0])
        expect(model.isSelectedNetwork(model.scanResults[0]) && !model.isSelectedNetwork(model.scanResults[1]),
               "selection includes the network security mode")
        model.applyDeviceStatus([("wifi.ap.begin", "1"), ("wifi.ap.end", "1")])
        expect(model.scanResults.isEmpty && model.wifiScanStatus == "ready",
               "zero results is a successful empty scan")
        model.applyDeviceStatus([("wifi.scan.status", "failed")])
        expect(model.wifiScanStatus == "failed" && !model.wifiScanning,
               "scan failure is distinct and can be retried")
        model.applyDeviceStatus([("wifi.ap.begin", "1"), ("wifi.ap", "Late AP\t-40\t1"),
                                 ("wifi.ap.end", "1")])
        expect(model.wifiScanStatus == "failed" && model.scanResults.isEmpty,
               "a late result batch cannot overwrite scan failure")
        model.applyDeviceStatus([("wifi.scan.status", "scanning"), ("wifi.ap.begin", "1"),
                                 ("wifi.ap", "Interrupted AP\t-40\t1"),
                                 ("wifi.scan.status", "failed"), ("wifi.ap.end", "1")])
        expect(model.wifiScanStatus == "failed" && model.scanResults.isEmpty,
               "failure inside a result batch discards the incomplete scan")
        model.applyDeviceStatus([("wifi.scan.status", "scanning"), ("wifi.ap.begin", "1"),
                                 ("wifi.ap.end", "0")])
        expect(model.wifiScanStatus == "ready", "a subsequent scan can recover from failure")

        model.selectNetwork(WifiAP(ssid: "Open AP", rssi: -42, secure: false))
        model.wifiPassword = "stale-test-input"
        expect(model.canWriteWifi, "open networks do not require a password")
        model.wifiConnect()
        expect(sent.count == 1 && sent[0].map { $0.0 } == ["wifi.ssid", "wifi.pass", "cmd.wifi"],
               "SSID, password and connect are sent in order")
        expect(sent[0][1].1.isEmpty && sent[0][2].1 == "connect",
               "open network always writes an empty password")
        expect(model.wifiPassword.isEmpty, "password is cleared as soon as queued")
        drainCallbacks()
        expect(model.wifiState != "connected", "queueing credentials does not claim Wi-Fi connected")

        model.selectNetwork(WifiAP(ssid: "Secured AP", rssi: -40, secure: true))
        expect(!model.canWriteWifi, "encrypted network requires input")
        for invalidSSID in ["line\ncmd.wifi=disconnect", "line\r\nnext", "tab\tname", "nul\0name",
                            String(repeating: "x", count: 33), String(repeating: "网", count: 11)] {
            model.selectNetwork(WifiAP(ssid: invalidSSID, rssi: -40, secure: false))
            let count = sent.count
            model.wifiConnect()
            expect(sent.count == count, "SSID limits and line-protocol injection are rejected")
        }
        model.selectNetwork(WifiAP(ssid: "Secured AP", rssi: -40, secure: true))
        for invalidPassword in ["line\ncmd.wifi=scan", "line\r\nnext", "tab\tvalue", "nul\0value",
                                String(repeating: "z", count: 64), String(repeating: "密", count: 22)] {
            model.wifiPassword = invalidPassword
            let count = sent.count
            model.wifiConnect()
            expect(sent.count == count, "password bounds and protocol injection are rejected")
        }
        model.wifiPassword = String(repeating: "a", count: 64)
        expect(model.canWriteWifi, "64 hexadecimal digits are a valid PSK")
        model.wifiPassword = String(repeating: "x", count: 63)
        expect(model.canWriteWifi, "63-byte password is accepted")
        model.wifiConnect()
        expect(model.wifiPassword.isEmpty, "encrypted password is removed from form after sending")
        drainCallbacks()
        expect(!defaults.dictionaryRepresentation().keys.contains { $0.contains("wifi") && $0.contains("pass") },
               "Wi-Fi password is never persisted in defaults")
        expect(!capturedLogs.contains { $0.contains("test-input-only") || $0.contains("stale-test-input") },
               "Wi-Fi password is never logged")

        let other = DeviceConfigModel(sender: { _, done in done(true) },
                                      deviceKey: "B", defaults: defaults, enableDebugChannel: false)
        expect(other.selectedSSID.isEmpty && other.wifiSetupRequest == nil && !other.bootChimeEnabled,
               "another device has independent selection and music state")
        model.wifiPassword = "not-for-next-connection"
        model.applyLinkChange(connected: false, name: nil)
        expect(model.wifiPassword.isEmpty && model.selectedSSID.isEmpty && model.wifiSetupRequest == nil,
               "disconnect clears pending network and password")

        var trustCommands: [(UInt8, String)] = []
        let trustModel = DeviceConfigModel(
            sender: { _, done in done(true) },
            trustSender: { operation, value, done in
                trustCommands.append((operation, value))
                done(true)
            },
            deviceKey: "trust", defaults: defaults, enableDebugChannel: false)
        trustModel.isConnected = true
        var auth = CompanionAuthSnapshot()
        auth.currentID = "this-installation"
        auth.currentName = CompanionNamePolicy.platformDefault
        auth.trusted = [
            .init(id: "this-installation", name: CompanionNamePolicy.platformDefault),
            .init(id: "other-installation", name: "家里的 Mac"),
        ]
        trustModel.applyAuthSnapshot(auth)
        expect(trustModel.companionName == CompanionNamePolicy.platformDefault,
               "a fresh install uses a private platform default name")
        expect(defaults.string(forKey: CompanionNamePolicy.defaultsKey) ==
               CompanionNamePolicy.platformDefault,
               "the installation name uses one stable global defaults key")

        trustModel.setCompanionNameDraft("我的\n\t电脑\0")
        expect(trustModel.companionNameDraft == "我的电脑",
               "protocol controls are visibly filtered from edited names")
        trustModel.setCompanionNameDraft(String(repeating: "名", count: 17))
        trustModel.saveCompanionName()
        expect(trustCommands.isEmpty,
               "a UTF-8 name over 48 bytes is rejected instead of truncated")

        trustModel.setCompanionNameDraft("工作 iPhone")
        trustModel.saveCompanionName()
        drainCallbacks()
        expect(trustCommands.last?.0 == 0x08 && trustCommands.last?.1 == "工作 iPhone",
               "saving the local name uses authenticated command 0x08")
        expect(defaults.string(forKey: CompanionNamePolicy.defaultsKey) ==
               CompanionNamePolicy.platformDefault,
               "transport acceptance alone does not persist an unconfirmed name")
        expect(trustModel.trustNotice.contains("等待 Passport 确认"),
               "transport acceptance does not claim Passport confirmation")
        auth.currentName = "工作 iPhone"
        auth.reason = "companion_name_changed"
        trustModel.applyAuthSnapshot(auth)
        expect(trustModel.companionName == "工作 iPhone" &&
               trustModel.trustNotice == "本机名称已保存到 Passport。",
               "the UI reports success only after the Passport snapshot echoes the name")
        expect(defaults.string(forKey: CompanionNamePolicy.defaultsKey) == "工作 iPhone",
               "Passport confirmation persists the name for future HELLO payloads")

        trustModel.setCompanionNameDraft("不会保存")
        trustModel.saveCompanionName()
        drainCallbacks()
        auth.reason = "companion_name_save_failed"
        auth.currentName = "工作 iPhone"
        trustModel.applyAuthSnapshot(auth)
        expect(trustModel.companionNameDraft == "工作 iPhone" &&
               trustModel.trustNotice.contains("保存名称失败"),
               "an NVS save failure clears the pending edit immediately")

        trustModel.connect(auth.trusted[1])
        trustModel.yieldConnection()
        trustModel.forget(auth.trusted[1])
        expect(trustCommands.suffix(3).map { $0.0 } == [0x05, 0x06, 0x03],
               "paired-device connect, disconnect and forget use the documented commands")
        print("device config tests: PASS")
    }
}
