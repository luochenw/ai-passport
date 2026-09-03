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
        // 只有一台的时候不占地方 —— 单设备用户不该为多设备功能付出界面成本。
        if model.devices.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.devices) { d in
                        Button { model.onSelect?(d.id) } label: {
                            HStack(spacing: 5) {
                                // 绿点 = 连着(它自己的会话在跑);高亮 = 界面
                                // 正在看这一台。两件事必须分开画:三台都连着时
                                // 三台都在工作,高亮的只是你正在看的那一台。
                                Circle()
                                    .fill(d.connected ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(shortName(d.name))
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
        } else if let only = model.devices.first, !only.connected {
            // 只扫到一台、还没连上:说清楚在等什么,不要让人对着空白等。
            Text("正在连接 \(shortName(only.name))…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
        }
    }

    private func helpText(_ d: BLERelay.DiscoveredDevice) -> String {
        if d.displayed { return "正在看这一台" }
        if d.connected { return "已连接、正在独立运行。点击查看这一台" }
        return "还没连上,正在重试"
    }

    /// "FoloPassport-2C44" 这一整串在按钮上太长,列表里每台都以 FoloPassport
    /// 开头,真正用来区分的只有后缀。
    private func shortName(_ n: String) -> String {
        n.hasPrefix(BLERelay.namePrefix + "-")
            ? String(n.dropFirst(BLERelay.namePrefix.count + 1))
            : n
    }
}
