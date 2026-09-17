import Foundation
import SwiftUI

// =====================================================================
// 设备设置页。
//
// 这里只放**属于硬件本身**的设置:音量、亮度、Wi-Fi、状态栏显示项,以及
// 蓝牙连接本身的控制。这些会写进设备的 NVS,断开电脑也保留。
//
// 各个应用的参数(接口地址、账号口令这些)不在这里 —— 那是应用的内部实现,
// 由应用自己管 —— 那是应用的内部实现。摊到这一页来
// 既暴露了不该暴露的东西,也会让这页随着应用变多而越来越乱。
//
// Passport 可以浏览设置、扫描并选择 Wi-Fi。需要密码时,通过状态通道把
// 选择同步到手机或电脑,由这里输入密码并写入设备。
//
// 双向的
// ──────
// 下发走 device_config 的 WRITE 特征值;设备的实际状态(连着哪个 Wi-Fi、
// 扫到了什么、当前音量亮度)走 STATUS 特征值(NOTIFY)推回来,由
// applyDeviceStatus() 灌进这个 model。没有这条反向通道的话,这一页只能显示
// "我发过去的值",而不是"设备现在真实的样子" —— 两者在下发失败时会不一致,
// 而界面看不出来。
// =====================================================================

struct WifiAP: Identifiable, Equatable {
    var id: String { (secure ? "1:" : "0:") + ssid }
    let ssid: String
    let rssi: Int
    let secure: Bool
}

final class DeviceConfigModel: ObservableObject {
    // ---- 硬件设置 ----
    @Published var volume: Double = 60
    @Published var brightness: Double = 100
    @Published var bootChimeEnabled = false
    @Published var bootChimeVolume: Double = 20
    @Published private(set) var bootChimeLoaded = false
    @Published private(set) var settingsSaving = false

    // ---- 状态栏显示项 ----
    @Published var sbBattery = true
    @Published var sbBle = true
    @Published var sbWifi = true
    @Published var sbTime = true

    // ---- 蓝牙链路 ----
    @Published var isConnected = false
    @Published var deviceName: String = ""
    @Published var statusText = "等待设备连接…"

    // ---- 伴侣认证 ----
    @Published var authState = "disconnected"
    @Published var authStatusText = "未认证"
    @Published var passportID = ""
    @Published var alias = ""
    @Published var aliasDraft = ""
    @Published var currentCompanionID = ""
    @Published var trustedCompanions: [CompanionAuthSnapshot.TrustedCompanion] = []
    @Published var trustNotice = ""
    @Published private(set) var companionName = CompanionNamePolicy.platformDefault
    @Published var companionNameDraft = CompanionNamePolicy.platformDefault

    private var pendingCompanionName: String?

    var isAuthorized: Bool { authState == "authorized" && isConnected }

    // ---- 设备侧 Wi-Fi ----
    @Published var wifiState = "off"        // off/idle/connecting/connected/failed
    @Published var wifiSSID = ""
    @Published var wifiIP = ""
    @Published var wifiRSSI = 0
    @Published var wifiScanning = false
    @Published private(set) var wifiScanStatus = "idle"
    @Published var scanResults: [WifiAP] = []
    @Published private(set) var selectedSSID = ""
    @Published private(set) var selectedRequiresPassword = true
    @Published private(set) var selectedOnDevice = false
    @Published private(set) var wifiSetupRequest: UUID?
    @Published private(set) var wifiWriteInFlight = false
    @Published private(set) var wifiNotice = ""
    /// ⚠ 只放在内存里,不写 UserDefaults、不进日志。这是别人家的 Wi-Fi 密码。
    @Published var wifiPassword = ""

    private let sender: ([(String, String)], @escaping (Bool) -> Void) -> Void
    private let bleDisconnect: () -> Void
    private let bleRescan: () -> Void
    private let trustSender: (UInt8, String, @escaping (Bool) -> Void) -> Void

    /// 扫描结果是一行一行推过来的,用 begin/end 括起来。收齐了再整体替换 ——
    /// 边收边往界面上加的话,列表会在扫描过程中不停跳动。
    private var pendingScan: [WifiAP] = []
    private var collectingScan = false
    private var deviceSelectedSSID = ""
    private var devicePasswordRequired = false
    private var scanRequestID: UUID?
    private var settingsRequestID: UUID?
    private var pendingSettings: [String: String]?
    private var reportedSettings: [String: String] = [:]
    private let defaults: UserDefaults

    /// 这一台自己的配置存在哪儿。
    ///
    /// ⚠ 音量、亮度、状态栏显示哪几项 —— 这些是**这一台设备**的设置,不是
    /// 这台电脑的。以前存的是全局键(`cfg.volume` 之类),两台设备读到同一
    /// 份:在 A 上把亮度调到 30,B 的滑块下次启动也变成 30,而 B 的屏幕
    /// 其实还是 100。用户在两台设备之间来回改,永远调不对。
    private let keyPrefix: String

    private func key(_ name: String) -> String { name + keyPrefix }

    /// 单设备时代用的是不带后缀的键。第一次用某台设备时从那里播种,
    /// 老用户升级上来不会发现自己调好的音量亮度全部回到默认值。
    init(sender: @escaping ([(String, String)], @escaping (Bool) -> Void) -> Void,
         bleDisconnect: @escaping () -> Void = {},
         bleRescan: @escaping () -> Void = {},
         trustSender: @escaping (UInt8, String, @escaping (Bool) -> Void) -> Void = { _, _, done in done(false) },
         deviceKey: String? = nil,
         defaults: UserDefaults = .standard,
         enableDebugChannel: Bool = true) {
        self.sender = sender
        self.bleDisconnect = bleDisconnect
        self.bleRescan = bleRescan
        self.trustSender = trustSender
        self.defaults = defaults
        self.keyPrefix = deviceKey.map { "." + $0 } ?? ""
        let d = defaults
        func dbl(_ name: String, _ fallback: Double) -> Double {
            (d.object(forKey: name + keyPrefix) as? Double)
                ?? (d.object(forKey: name) as? Double) ?? fallback
        }
        func bool(_ name: String, _ fallback: Bool) -> Bool {
            (d.object(forKey: name + keyPrefix) as? Bool)
                ?? (d.object(forKey: name) as? Bool) ?? fallback
        }
        volume     = dbl("cfg.volume", 60)
        brightness = dbl("cfg.brightness", 100)
        sbBattery  = bool("cfg.sb.battery", true)
        sbBle      = bool("cfg.sb.ble", true)
        sbWifi     = bool("cfg.sb.wifi", true)
        sbTime     = bool("cfg.sb.time", true)
        let localName = CompanionNamePolicy.load(defaults: d)
        companionName = localName
        companionNameDraft = localName
        // 调试通道是文件轮询,每台各开一条会攒出一堆定时器抢同一个文件。
        if enableDebugChannel { pollDebugPush() }
    }

    // MARK: 下发

    private var statusBarItems: String {
        // 设备侧按逗号分隔的名字列表解析(见 main/ui_statusbar.c 的 item_on)。
        var items: [String] = []
        if sbBattery { items.append("battery") }
        if sbBle     { items.append("ble") }
        if sbWifi    { items.append("wifi") }
        if sbTime    { items.append("time") }
        // 一项都不勾时发一个空串,设备那边就什么都不显示 —— 这是合法状态,
        // 不要退回默认值,否则用户会发现"全部取消勾选"根本没用。
        return items.joined(separator: ",")
    }

    /// 下发设备侧配置。
    func pushDeviceSettings() {
        guard isConnected, !settingsSaving else { return }
        let d = defaults
        d.set(volume, forKey: key("cfg.volume"))
        d.set(brightness, forKey: key("cfg.brightness"))
        d.set(sbBattery, forKey: key("cfg.sb.battery"))
        d.set(sbBle, forKey: key("cfg.sb.ble"))
        d.set(sbWifi, forKey: key("cfg.sb.wifi"))
        d.set(sbTime, forKey: key("cfg.sb.time"))

        sendSettings([("volume", String(Int(volume))),
                      ("brightness", String(Int(brightness))),
                      ("sb.items", statusBarItems)])
    }

    func pushBootChimeSettings() {
        // 两个初始值只是 UI 占位;开关和音量都读到后才允许保存。
        guard isConnected, !settingsSaving, bootChimeLoaded else { return }
        guard bootChimeVolume.isFinite, (0...100).contains(bootChimeVolume) else {
            statusText = "开机音乐音量必须在 0% 到 100% 之间。"
            return
        }
        sendSettings([("boot_chime.enabled", bootChimeEnabled ? "1" : "0"),
                      ("boot_chime.volume", String(Int(bootChimeVolume.rounded())))])
    }

    private func sendSettings(_ pairs: [(String, String)]) {
        let requestID = UUID()
        settingsRequestID = requestID
        pendingSettings = Dictionary(uniqueKeysWithValues: pairs)
        settingsSaving = true
        statusText = "正在写入到设备…"
        sender(pairs) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.settingsRequestID == requestID else { return }
                if ok {
                    self.statusText = "已发送，等待设备确认。"
                } else {
                    self.finishSettingsRequest("写入失败，请检查设备连接。")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.settingsRequestID == requestID else { return }
            self.finishSettingsRequest("未收到设备的保存确认，请检查连接后重试。")
        }
    }

    private func finishSettingsRequest(_ message: String) {
        settingsRequestID = nil
        pendingSettings = nil
        settingsSaving = false
        statusText = message
    }

    /// 时间同步。设备没有 RTC、也不联网,时间只能从这边来。
    ///
    /// 发 UTC 秒 + 分钟偏移两个值,而不是直接发本地时间 —— 把本地时间灌进
    /// 设备的系统时钟会让任何依赖真实时间的东西悄悄错上几个时区,偏移只该在
    /// 显示的那一刻加。设备侧见 main.c 的 apply_time_sync()。
    func syncTime() {
        let now = Int(Date().timeIntervalSince1970)
        let tzMinutes = TimeZone.current.secondsFromGMT() / 60
        // ⚠ 时间用 cmd.time(动作,设备不落盘),时区用 tzmin(普通配置,要存)。
        // 时间存进设备 NVS 的话,下次不连电脑单独开机会读出一个**陈旧但看起来
        // 完全合理**的时间显示在状态栏上 —— 那比显示 --:-- 糟糕得多,用户没有
        // 任何线索知道它是错的。时区不一样,它是长期事实,该存。
        sender([("cmd.time", String(now)), ("tzmin", String(tzMinutes))]) { ok in
            log(ok ? "[config] 时间已同步(tz \(tzMinutes) 分钟)" : "[config] 时间同步失败")
        }
    }

    // MARK: Wi-Fi

    func wifiScan() {
        guard isConnected, !wifiScanning else { return }
        wifiNotice = ""
        wifiScanning = true
        wifiScanStatus = "scanning"
        let requestID = UUID()
        scanRequestID = requestID
        // cmd.* 是动作不是配置,设备侧不会把它存进 NVS(见 device_config.h)。
        sender([("cmd.wifi", "scan")]) { [weak self] ok in
            if !ok {
                DispatchQueue.main.async {
                    guard let self, self.scanRequestID == requestID else { return }
                    self.finishScanFailure("扫描请求未发送，请检查设备连接。")
                }
            }
        }
        // 状态通知丢失时也要给用户一个可重试的入口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.scanRequestID == requestID, self.wifiScanning else { return }
            self.finishScanFailure("等待扫描结果超时，请重新扫描。")
        }
    }

    func selectNetwork(_ ap: WifiAP) {
        selectNetwork(ssid: ap.ssid, requiresPassword: ap.secure, onDevice: false)
    }

    func isSelectedNetwork(_ ap: WifiAP) -> Bool {
        selectedSSID == ap.ssid && selectedRequiresPassword == ap.secure
    }

    private func selectNetwork(ssid: String, requiresPassword: Bool, onDevice: Bool) {
        if selectedSSID != ssid || selectedRequiresPassword != requiresPassword {
            wifiPassword = ""
        }
        selectedSSID = ssid
        selectedRequiresPassword = requiresPassword
        selectedOnDevice = onDevice
        wifiNotice = ""
    }

    private static func hasProtocolDelimiter(_ text: String) -> Bool {
        text.utf8.contains { $0 == 0 || $0 == 9 || $0 == 10 || $0 == 13 }
    }

    var wifiValidationMessage: String? {
        guard !selectedSSID.isEmpty else { return "请先选择一个 Wi-Fi 网络。" }
        guard selectedSSID.utf8.count <= 32, !Self.hasProtocolDelimiter(selectedSSID) else {
            return "网络名称最多 32 字节，且不能含换行、制表符或空字符。"
        }
        guard selectedRequiresPassword else { return nil }
        guard !wifiPassword.isEmpty else { return "请输入此网络的密码。" }
        guard !Self.hasProtocolDelimiter(wifiPassword) else {
            return "密码不能含换行、制表符或空字符。"
        }
        let bytes = wifiPassword.utf8
        let isHexPSK = bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
        guard bytes.count <= 63 || isHexPSK else {
            return "密码最多 63 字节，或使用 64 位十六进制密钥。"
        }
        return nil
    }

    var canWriteWifi: Bool {
        isConnected && !wifiWriteInFlight && wifiState != "connecting" && wifiValidationMessage == nil
    }

    func wifiConnect() {
        guard isConnected, !wifiWriteInFlight, wifiState != "connecting" else { return }
        if let message = wifiValidationMessage {
            wifiNotice = message
            return
        }
        wifiNotice = "正在写入到设备…"
        wifiWriteInFlight = true
        // 凭据先落到设备的 NVS,再发连接命令 —— 两条写入是同一次 BLE 下发里
        // 按顺序处理的,设备侧逐行解析,所以到 cmd.wifi=connect 那一行时
        // ssid/pass 已经就位。
        let pairs = [("wifi.ssid", selectedSSID),
                     ("wifi.pass", selectedRequiresPassword ? wifiPassword : ""),
                     ("cmd.wifi", "connect")]
        // 发送队列接管后立即清空表单,不让后来的完成回调擦掉用户新输入的密码。
        wifiPassword = ""
        sender(pairs) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.wifiWriteInFlight = false
                guard self.isConnected else { return }
                self.wifiNotice = ok ? "已发送，等待设备报告连接结果。" : "写入失败，请检查设备连接后重试。"
            }
        }
    }

    func wifiDisconnect() {
        wifiPassword = ""
        sender([("cmd.wifi", "disconnect")]) { _ in }
    }

    private func finishScanFailure(_ message: String) {
        wifiScanning = false
        wifiScanStatus = "failed"
        scanRequestID = nil
        pendingScan = []
        collectingScan = false
        wifiNotice = message
    }

    // MARK: 蓝牙

    func disconnectBluetooth() { bleDisconnect() }
    func rescanBluetooth()     { bleRescan() }

    // MARK: 伴侣认证

    var companionNameValidationMessage: String? {
        CompanionNamePolicy.validationMessage(for: companionNameDraft)
    }

    func setCompanionNameDraft(_ value: String) {
        // Pasted text may contain controls even though this renders as one line.
        // Remove them immediately so the edit the user sees is the value sent.
        companionNameDraft = CompanionNamePolicy.sanitized(value)
        if trustNotice.hasPrefix("名称") { trustNotice = "" }
    }

    func refreshCompanionName() {
        guard pendingCompanionName == nil else { return }
        let value = CompanionNamePolicy.load(defaults: defaults)
        companionName = value
        companionNameDraft = value
    }

    func saveCompanionName() {
        let value = CompanionNamePolicy.normalized(companionNameDraft)
        companionNameDraft = value
        if let message = CompanionNamePolicy.validationMessage(for: value) {
            trustNotice = message
            return
        }
        guard isAuthorized else {
            trustNotice = "请先连接并认证 Passport。"
            return
        }
        pendingCompanionName = value
        trustNotice = "正在保存本机名称…"
        trustSender(0x08, value) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.pendingCompanionName == value else { return }
                guard ok else {
                    self.pendingCompanionName = nil
                    self.trustNotice = "名称保存失败，请检查连接后重试。"
                    return
                }
                self.trustNotice = "已发送，等待 Passport 确认。"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.pendingCompanionName == value else { return }
            self.pendingCompanionName = nil
            self.trustNotice = "未收到 Passport 的名称确认，请重试。"
        }
    }

    func saveAlias() {
        let value = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 32 else {
            trustNotice = "名称最多 32 个 UTF-8 字节（中文通常占 3 字节）"
            return
        }
        trustNotice = "正在保存设备名称…"
        trustSender(0x01, value) { [weak self] ok in
            DispatchQueue.main.async {
                self?.trustNotice = ok ? "名称已发送，等待 Passport 确认" : "名称保存失败"
            }
        }
    }

    func yieldConnection() {
        trustNotice = "正在断开，稍后仍可从 Passport 重新选择本机…"
        trustSender(0x06, "") { [weak self] ok in
            DispatchQueue.main.async {
                if !ok { self?.trustNotice = "断开失败：设备可能正处于升级或通话中。" }
            }
        }
    }

    func connect(_ companion: CompanionAuthSnapshot.TrustedCompanion) {
        guard companion.id != currentCompanionID else { return }
        trustNotice = "正在切换到「\(companion.name)」…"
        trustSender(0x05, companion.id) { [weak self] ok in
            DispatchQueue.main.async {
                if !ok { self?.trustNotice = "切换失败：目标设备可能不在附近。" }
            }
        }
    }

    func forget(_ companion: CompanionAuthSnapshot.TrustedCompanion) {
        trustNotice = "正在移除「\(companion.name)」…"
        trustSender(0x03, companion.id) { [weak self] ok in
            DispatchQueue.main.async {
                self?.trustNotice = ok ? "已发送移除请求" : "移除失败"
            }
        }
    }

    /// 从认证 STATE 通道收到的快照。**必须在主线程调用**。
    func applyAuthSnapshot(_ snapshot: CompanionAuthSnapshot) {
        authState = snapshot.state
        authStatusText = snapshot.statusText
        passportID = snapshot.deviceID
        alias = snapshot.alias
        if aliasDraft.isEmpty || aliasDraft == alias { aliasDraft = snapshot.alias }
        currentCompanionID = snapshot.currentID
        trustedCompanions = snapshot.trusted
        if let pending = pendingCompanionName, snapshot.currentName == pending {
            pendingCompanionName = nil
            _ = CompanionNamePolicy.save(pending, defaults: defaults)
            companionName = pending
            companionNameDraft = pending
            trustNotice = "本机名称已保存到 Passport。"
        } else if snapshot.reason == "alias_changed" {
            trustNotice = "设备名称已保存"
            aliasDraft = snapshot.alias
        } else if snapshot.reason == "companion_name_changed" {
            trustNotice = "Passport 已更新本机名称。"
        } else if snapshot.reason == "companion_name_save_failed" {
            pendingCompanionName = nil
            companionNameDraft = companionName
            trustNotice = "Passport 保存名称失败，请重试。"
        } else if snapshot.reason == "busy" {
            trustNotice = "设备正在升级、通话或收发音频，暂时不能切换"
        }
    }

    // MARK: 设备推回来的状态

    /// 从 STATUS 通道收到的键值对。**必须在主线程调用**(BLE 回调里要 hop 过来)。
    func applyDeviceStatus(_ pairs: [(String, String)]) {
        let previousSelection = deviceSelectedSSID
        let previousPasswordRequired = devicePasswordRequired
        for (k, v) in pairs {
            switch k {
            case "volume":
                if let n = Double(v) { volume = n; reportedSettings[k] = v }
            case "brightness":
                if let n = Double(v) { brightness = n; reportedSettings[k] = v }
            case "boot_chime.enabled":
                if v == "0" || v == "1" {
                    bootChimeEnabled = (v == "1")
                    reportedSettings[k] = v
                }
            case "boot_chime.volume":
                if let n = Int(v), (0...100).contains(n) {
                    bootChimeVolume = Double(n)
                    reportedSettings[k] = String(n)
                }
            case "sb.items":
                let set = Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                sbBattery = set.contains("battery")
                sbBle     = set.contains("ble")
                sbWifi    = set.contains("wifi")
                sbTime    = set.contains("time")
                reportedSettings[k] = v
            case "wifi.state":
                wifiState = v
                if v == "connected" || v == "failed" || v == "connecting" { wifiNotice = "" }
            case "wifi.ssid":     wifiSSID = v
            case "wifi.ip":       wifiIP = v
            case "wifi.rssi":     wifiRSSI = Int(v) ?? 0
            case "wifi.selected": deviceSelectedSSID = v
            case "wifi.password_required": devicePasswordRequired = (v == "1")
            case "wifi.scanning":
                wifiScanning = (v == "1")
                if wifiScanning { wifiScanStatus = "scanning" }
            case "wifi.scan.status":
                guard ["idle", "scanning", "ready", "failed"].contains(v) else { break }
                wifiScanStatus = v
                wifiScanning = (v == "scanning")
                if v == "failed" {
                    finishScanFailure("设备扫描失败，请重试。")
                } else if v == "ready" || v == "idle" {
                    scanRequestID = nil
                }
            case "wifi.ap.begin":
                pendingScan = []
                collectingScan = true
            case "wifi.ap":
                guard collectingScan else { break }
                // "<ssid>\t<rssi>\t<0|1>" —— 制表符分隔,SSID 里几乎不可能有。
                let f = v.components(separatedBy: "\t")
                guard f.count == 3, !f[0].isEmpty, f[0].utf8.count <= 32,
                      !Self.hasProtocolDelimiter(f[0]), let rssi = Int(f[1]),
                      f[2] == "0" || f[2] == "1" else { break }
                let ap = WifiAP(ssid: f[0], rssi: rssi, secure: f[2] == "1")
                if let existing = pendingScan.firstIndex(where: { $0.id == ap.id }) {
                    if ap.rssi > pendingScan[existing].rssi { pendingScan[existing] = ap }
                } else {
                    pendingScan.append(ap)
                }
            case "wifi.ap.end":
                guard collectingScan else { break }
                collectingScan = false
                // 失败状态与列表帧来自不同任务;迟到的列表结束帧不能把失败
                // 改成“扫描成功但没有网络”。下一次 scanning/ready 会解除它。
                guard wifiScanStatus != "failed" else {
                    pendingScan = []
                    break
                }
                scanResults = pendingScan.sorted { $0.rssi > $1.rssi }
                pendingScan = []
                wifiScanning = false
                wifiScanStatus = "ready"
                scanRequestID = nil
            default:
                break   // 认不出来的键忽略,方便设备侧先加字段再补界面
            }
        }
        bootChimeLoaded = reportedSettings["boot_chime.enabled"] != nil &&
                          reportedSettings["boot_chime.volume"] != nil
        if let pendingSettings, pendingSettings.allSatisfy({ reportedSettings[$0.key] == $0.value }) {
            finishSettingsRequest("已保存到设备")
        }
        // 一批 STATUS 可能按键排序回放,因此收齐后再关联 SSID 和密码要求。
        // 重复快照不能清掉用户正在输入的密码,也不能反复抢回导航焦点。
        if previousSelection != deviceSelectedSSID || previousPasswordRequired != devicePasswordRequired {
            if deviceSelectedSSID.isEmpty {
                selectedOnDevice = false
                wifiSetupRequest = nil
            } else {
                selectNetwork(ssid: deviceSelectedSSID,
                              requiresPassword: devicePasswordRequired, onDevice: true)
                if devicePasswordRequired { wifiSetupRequest = UUID() }
            }
        }
    }

    func applyLinkChange(connected: Bool, name: String?) {
        isConnected = connected
        deviceName = name ?? ""
        if connected {
            statusText = "已连接 \(name ?? "设备")"
            // 一连上就对时。设备断电会忘掉时间,而它自己没有别的途径知道。
            syncTime()
        } else {
            statusText = "设备未连接"
            settingsRequestID = nil
            pendingSettings = nil
            reportedSettings = [:]
            settingsSaving = false
            bootChimeLoaded = false
            authState = "disconnected"
            authStatusText = "连接已断开"
            wifiState = "off"
            wifiSSID = ""; wifiIP = ""; wifiRSSI = 0
            scanResults = []; wifiScanning = false
            wifiScanStatus = "idle"
            selectedSSID = ""; wifiPassword = ""
            selectedRequiresPassword = true
            selectedOnDevice = false
            deviceSelectedSSID = ""; devicePasswordRequired = false
            wifiSetupRequest = nil
            wifiNotice = ""
            wifiWriteInFlight = false
            pendingScan = []; collectingScan = false
            scanRequestID = nil
        }
    }

    // MARK: 命令行通道

    /// 往 /tmp/folo_config_push 写 "<key>=<value>" 行,下发给设备。
    /// 只处理设备侧配置 —— 应用的配置属于应用自己(见各应用的实现)。
    private static let debugPushPath = "/tmp/folo_config_push"

    private func pollDebugPush() {
        // ⚠ 只在 macOS 上跑。这是个开发期调试钩子:在终端里往 /tmp 写个文件
        // 来驱动它。iOS 沙盒里既写不进那个路径、也没有终端能写,轮询永远
        // 命中不了,只剩每秒一次的空唤醒 —— 手机上那是白耗电。
        #if os(macOS)
        if let text = try? String(contentsOfFile: Self.debugPushPath, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: Self.debugPushPath)
            let pairs: [(String, String)] = text.split(separator: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
                return (String(t[t.startIndex..<eq]), String(t[t.index(after: eq)...]))
            }
            if !pairs.isEmpty {
                // 只打键名不打值 —— 里面可能是 Wi-Fi 密码。
                log("[config] 命令行触发,下发 \(pairs.count) 项: \(pairs.map { $0.0 }.joined(separator: ", "))")
                sender(pairs) { ok in
                    log(ok ? "[config] 下发完成" : "[config] 下发失败:设备未连接")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pollDebugPush()
        }
        #endif
    }
}

// =====================================================================

enum DeviceSettingsRoute: Hashable {
    case wifi
    case bluetooth
    case bootChime
    case firmware
}

struct DeviceConfigView: View {
    @ObservedObject var model: DeviceConfigModel
    let onOpen: (DeviceSettingsRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(spacing: 4) {
                        settingsEntry("Wi-Fi", icon: "wifi",
                                      detail: model.wifiState == "connected" ? model.wifiSSID : "扫描附近网络并连接",
                                      route: .wifi)
                        Divider()
                        settingsEntry("蓝牙", icon: "antenna.radiowaves.left.and.right",
                                      detail: model.authStatusText, route: .bluetooth)
                        Divider()
                        settingsEntry("开机音乐", icon: "music.note",
                                      detail: model.bootChimeLoaded
                                      ? (model.bootChimeEnabled ? "已开启 · 音量 \(Int(model.bootChimeVolume))%" : "已关闭")
                                      : "读取设备设置中…", route: .bootChime)
                        Divider()
                        settingsEntry("固件升级", icon: "arrow.down.circle",
                                      detail: "查看版本与更新 Passport", route: .firmware)
                    }
                    .padding(6)
                }

                GroupBox("声音与显示") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("播放音量").frame(width: 70, alignment: .leading)
                            Slider(value: $model.volume, in: 0...100, step: 5)
                            Text("\(Int(model.volume))").frame(width: 34)
                        }
                        HStack {
                            Text("亮度").frame(width: 48, alignment: .leading)
                            Slider(value: $model.brightness, in: 10...100, step: 5)
                            Text("\(Int(model.brightness))").frame(width: 34)
                        }
                        Text("最低亮度保留 10%，方便随时继续操作设备。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("顶部状态栏") {
                    VStack(alignment: .leading, spacing: 6) {
                        #if os(macOS)
                        HStack(spacing: 16) {
                            Toggle("电量", isOn: $model.sbBattery)
                            Toggle("蓝牙", isOn: $model.sbBle)
                            Toggle("Wi-Fi", isOn: $model.sbWifi)
                            Toggle("时间", isOn: $model.sbTime)
                        }
                        #else
                        Toggle("电量", isOn: $model.sbBattery)
                        Toggle("蓝牙", isOn: $model.sbBle)
                        Toggle("Wi-Fi", isOn: $model.sbWifi)
                        Toggle("时间", isOn: $model.sbTime)
                        #endif
                        Text("时间会在连接手机或电脑时自动同步。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                HStack {
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存到设备") { model.pushDeviceSettings() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isConnected || model.settingsSaving)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private func settingsEntry(_ title: String, icon: String, detail: String,
                               route: DeviceSettingsRoute) -> some View {
        Button { onOpen(route) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DeviceBootChimeSettingsView: View {
    @ObservedObject var model: DeviceConfigModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("开机音乐") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("播放开机音乐", isOn: $model.bootChimeEnabled)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("开机音乐音量")
                                Spacer()
                                Text("\(Int(model.bootChimeVolume))%")
                                    .monospacedDigit()
                            }
                            Slider(value: $model.bootChimeVolume, in: 0...100, step: 5)
                        }
                        Text("此音量单独控制开机音乐，0% 为静音。设置会保存在 Passport，下次开机生效。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(!model.isConnected || !model.bootChimeLoaded || model.settingsSaving)
                    .padding(6)
                }
                if !model.bootChimeLoaded {
                    Text("正在等待 Passport 报告开机音乐开关和音量。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存到设备") { model.pushBootChimeSettings() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isConnected || !model.bootChimeLoaded || model.settingsSaving)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}

struct DeviceWifiSettingsView: View {
    @ObservedObject var model: DeviceConfigModel

    private var wifiStateText: String {
        guard model.isConnected else { return "请先连接 Passport。" }
        switch model.wifiState {
        case "connected": return "已连接 \(model.wifiSSID)"
        case "connecting": return "正在连接 Wi-Fi…"
        case "failed": return "连接失败，请检查密码和信号。"
        default: return "Wi-Fi 未连接"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("设备 Wi-Fi") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(wifiStateText,
                              systemImage: model.wifiState == "connected" ? "wifi" : "wifi.slash")
                        if model.wifiState == "connected" {
                            Text("\(model.wifiIP)  ·  \(model.wifiRSSI) dBm")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("重新扫描") { model.wifiScan() }
                                .disabled(!model.isConnected || model.wifiScanning)
                            if model.wifiScanning { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("断开 Wi-Fi") { model.wifiDisconnect() }
                                .disabled(!model.isConnected || model.wifiState != "connected")
                        }
                        Text("扫描结果来自 Passport 的 Wi-Fi，显示设备附近的网络。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if !model.selectedSSID.isEmpty {
                    GroupBox("连接网络") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.selectedSSID,
                                  systemImage: model.selectedRequiresPassword ? "lock.fill" : "wifi")
                                .font(.headline)
                                .textSelection(.enabled)
                            if model.selectedOnDevice {
                                Text("已在 Passport 上选中，请在这里完成连接。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if model.selectedRequiresPassword {
                                SecureField("Wi-Fi 密码", text: $model.wifiPassword)
                                    .textContentType(.password)
                                    #if !os(macOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    #endif
                                Text("密码仅用于写入 Passport，不会保存在这台手机或电脑，也不会写入日志。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("这是开放网络，无需输入密码。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !model.wifiPassword.isEmpty, let error = model.wifiValidationMessage {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Text("写入后设备会连接此网络。")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button("写入到设备") { model.wifiConnect() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!model.canWriteWifi)
                            }
                        }
                        .padding(6)
                    }
                }

                if !model.wifiNotice.isEmpty {
                    Text(model.wifiNotice).font(.callout).foregroundStyle(.secondary)
                }

                GroupBox("附近网络") {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.scanResults.isEmpty {
                            Text(emptyScanText)
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 14)
                        } else {
                            ForEach(model.scanResults) { ap in
                                Button { model.selectNetwork(ap) } label: {
                                    networkRow(ap)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.wifiWriteInFlight)
                                if ap.id != model.scanResults.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(20)
        }
        .onAppear {
            if model.wifiScanStatus == "idle" { model.wifiScan() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private var emptyScanText: String {
        switch model.wifiScanStatus {
        case "scanning": return "Passport 正在扫描附近的 Wi-Fi…"
        case "ready": return "没有发现附近的 Wi-Fi，请靠近路由器后重新扫描。"
        case "failed": return "扫描未完成，请重新扫描。"
        default: return "点「重新扫描」查看 Passport 附近的 Wi-Fi。"
        }
    }

    private func networkRow(_ ap: WifiAP) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.isSelectedNetwork(ap) ? "checkmark.circle.fill" : "wifi")
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(ap.ssid).foregroundStyle(.primary)
                Text("\(ap.rssi) dBm · \(ap.secure ? "需要密码" : "开放网络")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ap.secure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

struct DeviceBluetoothSettingsView: View {
    @ObservedObject var model: DeviceConfigModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("本机") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle()
                                .fill(model.isConnected ? Color.blue : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(model.isConnected ? "已连接 \(model.deviceName)" : "未连接")
                            Spacer()
                            Button("重新连接") { model.rescanBluetooth() }
                        }
                        HStack {
                            TextField("本机名称", text: Binding(
                                get: { model.companionNameDraft },
                                set: { model.setCompanionNameDraft($0) }
                            ))
                            Button("保存名称") { model.saveCompanionName() }
                                .disabled(!model.isAuthorized ||
                                          model.companionNameValidationMessage != nil ||
                                          model.companionNameDraft == model.companionName)
                        }
                        Text("该名称会显示在 Passport 的蓝牙设置中，不会读取或公开系统设备名称。")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let validation = model.companionNameValidationMessage {
                            Text(validation).font(.caption2).foregroundStyle(.orange)
                        }
                        Text(model.authStatusText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("已配对设备") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(model.authStatusText,
                                  systemImage: model.isAuthorized ? "checkmark.shield.fill" : "shield")
                                .foregroundStyle(model.isAuthorized ? Color.green : Color.orange)
                            Spacer()
                            if !model.passportID.isEmpty {
                                Text("设备 \(model.passportID)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("最多保存 8 台手机或电脑，同一时间只能连接 1 台。")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.trustedCompanions.isEmpty {
                            Text("还没有收到已配对设备列表。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.trustedCompanions) { companion in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(companion.name.isEmpty ? "未命名设备" : companion.name)
                                        Text(companion.platformName +
                                             (companion.id == model.currentCompanionID ? " · 当前连接" : ""))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if companion.id == model.currentCompanionID {
                                        Button("断开") { model.yieldConnection() }
                                            .disabled(!model.isAuthorized)
                                    } else {
                                        Button("切换至此设备") { model.connect(companion) }
                                            .disabled(!model.isAuthorized)
                                    }
                                    Button("忘记", role: .destructive) { model.forget(companion) }
                                        .disabled(!model.isAuthorized)
                                }
                            }
                        }
                        Text("要配对新设备，请在 Passport 的「设置 → 蓝牙」中选择「开启配对发现」，再从手机或电脑发起连接。")
                            .font(.caption2).foregroundStyle(.secondary)
                        if !model.trustNotice.isEmpty {
                            Text(model.trustNotice).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Passport 名称") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Passport 名称", text: $model.aliasDraft)
                                #if !os(macOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Button("保存") { model.saveAlias() }
                                .disabled(!model.isAuthorized || model.aliasDraft.utf8.count > 32)
                        }
                        Text("这个名称用于在手机或电脑的 Passport 列表中区分设备。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

            }
            .padding(20)
        }
        .onAppear { model.refreshCompanionName() }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}
