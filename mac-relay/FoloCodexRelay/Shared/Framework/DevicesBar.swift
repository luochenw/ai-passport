import SwiftUI

/// 扫到的设备列表:哪几台连着(绿点),以及界面此刻在看哪一台(高亮)。
///
/// ⚠ 高亮**不是**"只有这台在工作"。每台连上的设备都有自己独立的会话
/// (DeviceSession):自己的应用、自己的浏览位置、在对讲服务器上自己的身份,
/// 全都在跑。高亮只说明下面三个页签显示的是谁的那一份。
///
/// 这段注释以前论证的是"不要做每设备页签,因为同一时刻只驱动一台" ——
/// 那个前提已经不成立了。照着旧注释改的人会把新架构改回去。
final class DevicesModel: ObservableObject {
    @Published var devices: [BLERelay.DiscoveredDevice] = []
    var onSelect: ((UUID) -> Void)?

    var displayed: BLERelay.DiscoveredDevice? { devices.first { $0.displayed } }
}

struct DevicesBar: View {
    @ObservedObject var model: DevicesModel

    var body: some View {
        // 单台且已经授权在线时仍不占地方；陌生/待确认/掉线设备必须可见，
        // 否则“陌生设备不自动连接”会变成用户没有任何入口能主动连接。
        if model.devices.count > 1 || model.devices.first.map({ !$0.authorized || !$0.connected }) == true {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.devices) { d in
                        Button { model.onSelect?(d.id) } label: {
                            HStack(spacing: 5) {
                                // 绿点 = 连着(它自己的会话在跑);高亮 = 界面
                                // 正在看这一台。两件事必须分开画:三台都连着时
                                // 三台都在工作,高亮的只是你正在看的那一台。
                                Circle()
                                    .fill(statusColor(d))
                                    .frame(width: 6, height: 6)
                                Text(d.alias.isEmpty ? shortName(d.name) : d.alias)
                                    .lineLimit(1)
                                    .fontWeight(d.displayed ? .semibold : .regular)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(d.displayed ? Color.accentColor.opacity(0.22)
                                                  : Color.secondary.opacity(0.10)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(d.displayed ? Color.accentColor.opacity(0.55)
                                                          : Color.clear, lineWidth: 1))
                        .help(helpText(d))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
    }

    private func statusColor(_ d: BLERelay.DiscoveredDevice) -> Color {
        if d.authorized { return .green }
        if d.connected { return .orange }
        return .secondary.opacity(0.4)
    }

    private func helpText(_ d: BLERelay.DiscoveredDevice) -> String {
        if d.displayed && d.authorized { return "正在看这一台" }
        if d.authorized { return "已认证、正在独立运行。点击查看这一台" }
        if d.connected { return d.authStatusText }
        return d.authState == "denied" ? "连接被拒绝；点击可手动重试" : "点击连接并认证"
    }

    /// "FoloPassport-2C44" 这一整串在按钮上太长,列表里每台都以 FoloPassport
    /// 开头,真正用来区分的只有后缀。
    private func shortName(_ n: String) -> String {
        n.hasPrefix(BLERelay.namePrefix + "-")
            ? String(n.dropFirst(BLERelay.namePrefix.count + 1))
            : n
    }
}
