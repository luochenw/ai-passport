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
// 为什么设置只在电脑上、不在设备上
// ────────────────────────────────
// 设备只有三个按键。在上面输入一个 Wi-Fi 密码是酷刑;而在电脑上敲一行字是
// 天经地义的事。设备端只负责显示结果。
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
    var id: String { ssid }
    let ssid: String
    let rssi: Int
    let secure: Bool
}

final class DeviceConfigModel: ObservableObject {
    // ---- 硬件设置 ----
    @Published var volume: Double = 60
    @Published var brightness: Double = 100

    // ---- 状态栏显示项 ----
    @Published var sbBattery = true
    @Published var sbBle = true
    @Published var sbWifi = true
    @Published var sbTime = true

    // ---- 蓝牙链路 ----
    @Published var isConnected = false
    @Published var deviceName: String = ""
    @Published var statusText = "等待设备连接…"

    // ---- 设备侧 Wi-Fi ----
    @Published var wifiState = "off"        // off/idle/connecting/connected/failed
    @Published var wifiSSID = ""
    @Published var wifiIP = ""
    @Published var wifiRSSI = 0
    @Published var wifiScanning = false
    @Published var scanResults: [WifiAP] = []
    @Published var selectedSSID = ""
    /// ⚠ 只放在内存里,不写 UserDefaults、不进日志。这是别人家的 Wi-Fi 密码。
    @Published var wifiPassword = ""

    private let sender: ([(String, String)], @escaping (Bool) -> Void) -> Void
    private let bleDisconnect: () -> Void
    private let bleRescan: () -> Void

    /// 扫描结果是一行一行推过来的,用 begin/end 括起来。收齐了再整体替换 ——
    /// 边收边往界面上加的话,列表会在扫描过程中不停跳动。
    private var pendingScan: [WifiAP] = []
    private var collectingScan = false

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
         deviceKey: String? = nil,
         enableDebugChannel: Bool = true) {
        self.sender = sender
        self.bleDisconnect = bleDisconnect
        self.bleRescan = bleRescan
        self.keyPrefix = deviceKey.map { "." + $0 } ?? ""
        let d = UserDefaults.standard
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
        let d = UserDefaults.standard
        d.set(volume, forKey: key("cfg.volume"))
        d.set(brightness, forKey: key("cfg.brightness"))
        d.set(sbBattery, forKey: key("cfg.sb.battery"))
        d.set(sbBle, forKey: key("cfg.sb.ble"))
        d.set(sbWifi, forKey: key("cfg.sb.wifi"))
        d.set(sbTime, forKey: key("cfg.sb.time"))

        statusText = "正在下发到设备…"
        sender([("volume", String(Int(volume))),
                ("brightness", String(Int(brightness))),
                ("sb.items", statusBarItems)]) { [weak self] ok in
            DispatchQueue.main.async {
                self?.statusText = ok ? "已下发到设备" : "下发失败:设备未连接"
            }
        }
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
        scanResults = []
        wifiScanning = true
        // cmd.* 是动作不是配置,设备侧不会把它存进 NVS(见 device_config.h)。
        sender([("cmd.wifi", "scan")]) { ok in
            if !ok { DispatchQueue.main.async { self.wifiScanning = false } }
        }
    }

    func wifiConnect() {
        guard !selectedSSID.isEmpty else { return }
        statusText = "正在让设备连接 \(selectedSSID)…"
        // 凭据先落到设备的 NVS,再发连接命令 —— 两条写入是同一次 BLE 下发里
        // 按顺序处理的,设备侧逐行解析,所以到 cmd.wifi=connect 那一行时
        // ssid/pass 已经就位。
        sender([("wifi.ssid", selectedSSID),
                ("wifi.pass", wifiPassword),
                ("cmd.wifi", "connect")]) { [weak self] ok in
            DispatchQueue.main.async {
                if ok {
                    // 密码已经交给设备了,界面上不要再留着。
                    self?.wifiPassword = ""
                } else {
                    self?.statusText = "下发失败:设备未连接"
                }
            }
        }
    }

    func wifiDisconnect() {
        sender([("cmd.wifi", "disconnect")]) { _ in }
    }

    // MARK: 蓝牙

    func disconnectBluetooth() { bleDisconnect() }
    func rescanBluetooth()     { bleRescan() }

    // MARK: 设备推回来的状态

    /// 从 STATUS 通道收到的键值对。**必须在主线程调用**(BLE 回调里要 hop 过来)。
    func applyDeviceStatus(_ pairs: [(String, String)]) {
        for (k, v) in pairs {
            switch k {
            case "volume":     if let n = Double(v) { volume = n }
            case "brightness": if let n = Double(v) { brightness = n }
            case "sb.items":
                let set = Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                sbBattery = set.contains("battery")
                sbBle     = set.contains("ble")
                sbWifi    = set.contains("wifi")
                sbTime    = set.contains("time")
            case "wifi.state":    wifiState = v
            case "wifi.ssid":     wifiSSID = v
            case "wifi.ip":       wifiIP = v
            case "wifi.rssi":     wifiRSSI = Int(v) ?? 0
            case "wifi.scanning": wifiScanning = (v == "1")
            case "wifi.ap.begin":
                pendingScan = []
                collectingScan = true
            case "wifi.ap":
                guard collectingScan else { break }
                // "<ssid>\t<rssi>\t<0|1>" —— 制表符分隔,SSID 里几乎不可能有。
                let f = v.components(separatedBy: "\t")
                guard f.count >= 3, !f[0].isEmpty else { break }
                pendingScan.append(WifiAP(ssid: f[0], rssi: Int(f[1]) ?? 0, secure: f[2] == "1"))
            case "wifi.ap.end":
                collectingScan = false
                scanResults = pendingScan
                wifiScanning = false
                if selectedSSID.isEmpty { selectedSSID = pendingScan.first?.ssid ?? "" }
            default:
                break   // 认不出来的键忽略,方便设备侧先加字段再补界面
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
            wifiState = "off"
            wifiSSID = ""; wifiIP = ""; wifiRSSI = 0
            scanResults = []; wifiScanning = false
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

struct DeviceConfigView: View {
    @ObservedObject var model: DeviceConfigModel

    private var wifiStateText: String {
        switch model.wifiState {
        case "connected":  return "已连接 \(model.wifiSSID)  \(model.wifiIP)  \(model.wifiRSSI) dBm"
        case "connecting": return "正在连接…"
        case "failed":     return "连接失败,检查密码"
        case "idle":       return "未连接"
        default:           return "未启动(点扫描或连接会自动启动)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // ---- 蓝牙链路 ----
                GroupBox("蓝牙") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(model.isConnected ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(model.isConnected ? "已连接 \(model.deviceName)" : "未连接")
                            Spacer()
                            Button("断开") { model.disconnectBluetooth() }
                                .disabled(!model.isConnected)
                            Button("重新扫描") { model.rescanBluetooth() }
                        }
                        Text(model.statusText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // ---- 硬件 ----
                GroupBox("硬件") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("音量").frame(width: 48, alignment: .leading)
                            Slider(value: $model.volume, in: 0...100, step: 5)
                            Text("\(Int(model.volume))").frame(width: 34)
                        }
                        HStack {
                            Text("亮度").frame(width: 48, alignment: .leading)
                            // 下限 10 不是 0:背光真给 0 就是全灭,而设备上没有
                            // 任何入口能把它调回来(见 device_config.h)。
                            Slider(value: $model.brightness, in: 10...100, step: 5)
                            Text("\(Int(model.brightness))").frame(width: 34)
                        }
                        Text("亮度最低 10% —— 给 0 屏幕会全黑,设备上没有能调回来的入口。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // ---- 状态栏 ----
                GroupBox("顶部状态栏") {
                    VStack(alignment: .leading, spacing: 6) {
                        // ⚠ 横排还是竖排,取决于 Toggle 在这个平台上长什么样,
                        // 不是审美问题:
                        //   · macOS 上 Toggle 是**复选框** —— 一个方框加一个紧挨着
                        //     的标签,四个并排轻松放得下;
                        //   · iOS 上 Toggle 是**开关** —— 标签在左、开关推到最右,
                        //     天生要占满一行。四个挤进 iPhone 竖屏的 390pt,标签会被
                        //     压扁、开关叠到文字上,看起来就是一片乱码。
                        // 所以这里按平台分,横排那版只在 macOS 上用。
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
                        Text("时间由这台电脑在连接时自动同步 —— 设备没有 RTC,断电会忘。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                HStack {
                    Spacer()
                    Button("下发到设备") { model.pushDeviceSettings() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isConnected)
                }

                // ---- 设备侧 Wi-Fi ----
                GroupBox("设备 Wi-Fi") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(wifiStateText).font(.caption)
                            Spacer()
                            if model.wifiScanning { ProgressView().controlSize(.small) }
                            Button("扫描") { model.wifiScan() }
                                .disabled(!model.isConnected || model.wifiScanning)
                            Button("断开") { model.wifiDisconnect() }
                                .disabled(model.wifiState != "connected")
                        }

                        if model.scanResults.isEmpty {
                            Text("还没有扫描结果。点「扫描」让设备扫一遍附近的网络。")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Picker("网络", selection: $model.selectedSSID) {
                                ForEach(model.scanResults) { ap in
                                    Text("\(ap.ssid)   \(ap.rssi) dBm\(ap.secure ? "" : "  (开放)")")
                                        .tag(ap.ssid)
                                }
                            }
                            // iOS 上 Picker 的默认样式在这种嵌在卡片里的场景会
                            // 铺成一整段占满高度的列表,把下面的密码框挤出屏幕。
                            // .menu 收成一个下拉,跟 macOS 的观感也一致。
                            .pickerStyle(.menu)
                        }

                        HStack {
                            SecureField("密码", text: $model.wifiPassword)
                                // ⚠ 不关自动大写的话,iOS 会把首字母改成大写 ——
                                // 而这是个密文框,用户**看不见**被改了什么,只会
                                // 看到设备连不上 Wi-Fi 却查不出原因。
                                #if !os(macOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                            Button("连接") { model.wifiConnect() }
                                .disabled(!model.isConnected || model.selectedSSID.isEmpty)
                        }
                        Text("密码只在下发的那一刻用一次,不保存在这台电脑上,也不写进日志。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // 这一页只放属于硬件本身的设置。各个应用的参数(接口地址、账号
                // 口令这些)归应用自己管 —— 它们是应用的内部实现,摊到这里既暴露
                // 了不该暴露的东西,也会让这一页随着应用变多而越来越乱。
                Text("应用的参数由各应用自己管理,不在这里配置。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        // 只有 macOS 需要:窗口是用户可拉的,给个不至于挤成一团的下限。
        // iPhone 上窗口就是屏幕,写死 460 会让内容横向溢出(iPhone
        // 竖屏逻辑宽度只有 390pt)。
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}
