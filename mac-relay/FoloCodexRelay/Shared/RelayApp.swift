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
            RootView(core: core)
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
            NavigationStack {
                RemoteAppsView(model: core.remoteAppsModel)
                    .navigationDestination(for: RemoteAppSettingsRoute.self) { route in
                        switch route {
                        case .walkieTalkie:
                            WalkieTalkieView(model: core.walkieApp)
                                .navigationTitle("对讲机设置")
                        }
                    }
            }
            .tabItem { Label("应用", systemImage: "square.grid.2x2") }
            DeviceConfigView(model: core.deviceConfigModel)
                .tabItem { Label("配置", systemImage: "gearshape") }
            AppStoreView(model: core.appStoreModel)
                .tabItem { Label("固件", systemImage: "arrow.down.circle") }
        }
        .padding(.top, 6)
    }
}
