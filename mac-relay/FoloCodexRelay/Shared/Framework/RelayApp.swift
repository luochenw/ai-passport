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
                WaitingForDeviceView()
            }
        }
        .padding(.top, 6)
    }
}

/// 一台设备的三个页签。谈的全部是**这一台**。
private struct SessionView: View {
    let session: DeviceSession
    /// 「应用」标签页的导航栈。每台各一份 —— 它是 `@State`,而外面套了
    /// `.id(deviceID)`,换设备时整棵子树重建,栈自然跟着归零。
    @State private var appSettingsPath = NavigationPath()

    var body: some View {
        // 三个一级页面放进一个标签窗口。应用自己的设置属于应用管理层级,
        // 通过「应用」列表进入,不为每个应用占一个顶层标签。
        //
        // ⚠「应用」和「固件」是两件**完全不同**的事,标签上必须分清楚,早先
        // 都叫"应用"是错的:
        //   · 应用 = 跑在这台电脑上的远程应用,装/卸是即时的,设备只显示;
        //   · 固件 = 整机镜像,通过蓝牙刷进设备的 appslot 分区,几分钟起步,
        //            而且刷坏了要靠 bootloader 的防砖逻辑救回来。
        // 两者放在同一个标签下,用户点"安装"时根本不知道自己触发的是哪一种。
        TabView {
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
                                .navigationTitle("吃饭设置")
                        }
                    }
            }
            .tabItem { Label("应用", systemImage: "square.grid.2x2") }
            DeviceConfigView(model: session.deviceConfigModel)
                .tabItem { Label("配置", systemImage: "gearshape") }
            AppStoreView(model: session.appStoreModel)
                .tabItem { Label("固件", systemImage: "arrow.down.circle") }
            #if os(iOS)
            // NFC 跟这台 DeviceSession、跟蓝牙都没关系 —— 手机直接跟设备上
            // 那颗 NTAG213 标签用 NFC 场通信,不经过 BLE。放进这个 TabView
            // 只是因为用户此刻大概率正拿着这台设备,不是因为它依赖 session。
            // Core NFC 只有 iOS 有,macOS 不出这个标签。
            NavigationStack {
                NFCToolView()
            }
            .tabItem { Label("NFC", systemImage: "wave.3.right.circle") }
            #endif
        }
    }
}

/// 一台都还没连上。说清楚在等什么,不要给一个空白的标签窗口。
private struct WaitingForDeviceView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在寻找 \(BLERelay.namePrefix) 设备…")
                .font(.callout)
            Text("每台连上的设备都会有自己独立的一套应用和对讲身份。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
