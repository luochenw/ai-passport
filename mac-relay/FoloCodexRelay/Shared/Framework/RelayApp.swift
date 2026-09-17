import SwiftUI

// =====================================================================
// 应用入口。三端共用。
//
// 原来这里是 AppKit 的 NSApplication + NSWindow + NSHostingController。
// 那不是真正的平台边界,只是历史包袱 —— 这个 app 最早只有 Mac 一端,
// 当时直接用了 AppKit。SwiftUI 的 `App` + `WindowGroup` 在 macOS /
// iOS / iPadOS 上语义一致,换过来之后外壳本身就三端通用了,不需要为
// iOS 单开一个入口文件、也不需要维护两份界面。
// =====================================================================

@main
struct RelayApp: App {
    // AppCore.shared 在第一次取用时完成全部接线并启动 BLE。放在这里而不是
    // 某个 View 的 onAppear 里:后者会随视图重建反复触发,而这些是进程级
    // 的一次性构造。
    private let core = AppCore.shared

    var body: some Scene {
        WindowGroup {
            RootView(core: core, router: core.router)
        }
        #if os(macOS)
        // macOS 上窗口是可以随便拉的,给个合适的初始尺寸。iOS 上窗口就是
        // 整个屏幕,这个修饰符没有意义(也不存在)。
        .defaultSize(width: 460, height: 560)
        #endif
    }
}

struct RootView: View {
    let core: AppCore
    /// ⚠ 必须是 `@ObservedObject`。每台设备有自己的一套模型,切设备就是换
    /// 一整组 `ObservableObject` —— 只有 router 本身可观察,SwiftUI 才知道
    /// 该重画。以前这里只有一个 `let core: AppCore`(不可观察),点设备条
    /// 界面根本不会有反应。
    @ObservedObject var router: SessionRouter

    var body: some View {
        VStack(spacing: 0) {
            DevicesBar(model: core.devicesModel)
            if let session = router.selected {
                // ⚠ `.id(deviceID)`:切设备时让 SwiftUI 把整棵子树**重建**,
                // 而不是把新模型塞进旧视图。后者会留下上一台的导航栈位置、
                // 滚动位置和展开状态 —— 看起来像"B 设备记得 A 的操作"。
                SessionView(session: session)
                    .id(session.deviceID)
            } else {
                WaitingForDeviceView(model: core.devicesModel)
            }
        }
        .padding(.top, 6)
    }
}

/// 一台设备的应用首页和设置。导航状态跟随这一台设备。
private struct SessionView: View {
    let session: DeviceSession
    @ObservedObject private var config: DeviceConfigModel
    /// 「应用」标签页的导航栈。每台各一份 —— 它是 `@State`,而外面套了
    /// `.id(deviceID)`,换设备时整棵子树重建,栈自然跟着归零。
    @State private var appSettingsPath = NavigationPath()
    @State private var deviceSettingsPath: [DeviceSettingsRoute] = []
    @State private var selectedTab = SessionTab.apps

    private enum SessionTab: Hashable { case apps, settings }

    init(session: DeviceSession) {
        self.session = session
        self.config = session.deviceConfigModel
    }

    var body: some View {
        // 应用商店留在首页；固件升级、Wi-Fi 和蓝牙从设置进入。
        TabView(selection: $selectedTab) {
            // ⚠ path 由外面拿着,入口用显式 Button 往里 append。
            //
            // 原来是在 List 行里放 NavigationLink(value:) + .buttonStyle(.plain)。
            // macOS 上那样点不动:List 行本身有选中逻辑,同一行里又有图标
            // 下拉的 Menu,三者抢同一次点击,plain 样式的 NavigationLink 经常
            // 一次都收不到。改成受控 path 之后,点击目标只有齿轮那一个按钮,
            // 谁响应是确定的。
            NavigationStack(path: $appSettingsPath) {
                RemoteAppsView(model: session.remoteAppsModel,
                               onOpenSettings: { appSettingsPath.append($0) })
                    .navigationDestination(for: RemoteAppSettingsRoute.self) { route in
                        switch route {
                        case .walkieTalkie:
                            WalkieTalkieView(model: session.walkieCapability)
                                .navigationTitle("对讲机设置")
                        case .meal:
                            MealSettingsView(model: session.mealCapability)
                                .navigationTitle("字节餐厅设置")
                        }
                    }
            }
            .tabItem { Label("应用商店", systemImage: "square.grid.2x2") }
            .tag(SessionTab.apps)
            NavigationStack(path: $deviceSettingsPath) {
                DeviceConfigView(model: config, onOpen: { deviceSettingsPath.append($0) })
                    .navigationTitle("设置")
                    .navigationDestination(for: DeviceSettingsRoute.self) { route in
                        switch route {
                        case .wifi:
                            DeviceWifiSettingsView(model: config)
                                .navigationTitle("Wi-Fi")
                        case .bootChime:
                            DeviceBootChimeSettingsView(model: config)
                                .navigationTitle("开机音乐")
                        case .bluetooth:
                            DeviceBluetoothSettingsView(model: config)
                                .navigationTitle("蓝牙")
                        case .firmware:
                            AppStoreView(model: session.appStoreModel)
                                .navigationTitle("固件升级")
                        }
                    }
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(SessionTab.settings)
        }
        .onReceive(config.$wifiSetupRequest) { request in
            guard request != nil else { return }
            selectedTab = .settings
            if deviceSettingsPath != [.wifi] { deviceSettingsPath = [.wifi] }
        }
    }
}

/// 一台都还没连上。说清楚在等什么,不要给一个空白的标签窗口。
private struct WaitingForDeviceView: View {
    @ObservedObject var model: DevicesModel

    private var headline: String {
        guard let device = model.devices.first(where: { $0.displayed }) ?? model.devices.first else {
            return "正在寻找 \(BLERelay.namePrefix) 设备…"
        }
        if device.connected { return device.authStatusText }
        if device.authState == "denied" { return device.authStatusText }
        return "已发现 \(device.alias.isEmpty ? device.name : device.alias)"
    }

    private var detail: String {
        guard let device = model.devices.first(where: { $0.displayed }) ?? model.devices.first else {
            return "陌生设备不会自动连接；发现后请在上方设备条中点选。"
        }
        if device.connected {
            return "首次添加时，请同时确认系统蓝牙配对提示，并在 Passport 上核对后按确定。"
        }
        if device.authState == "denied" {
            return "请检查 Passport 的「设置 → 蓝牙」，然后点上方设备手动重试。"
        }
        return "点上方设备开始连接。首次配对前，请先在 Passport 的「设置 → 蓝牙」中选择「开启配对发现」，然后按屏幕提示确认。"
    }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(headline)
                .font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
