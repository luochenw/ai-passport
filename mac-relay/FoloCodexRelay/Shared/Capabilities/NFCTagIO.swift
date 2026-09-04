import Foundation
import SwiftUI
#if os(iOS)
import CoreNFC
#endif

// =====================================================================
// NFC 标签读写:读/写设备上那颗 NTAG213 无源标签(NDEF 格式)。
//
// 跟 BLE 连接、跟 DeviceSession 都没有关系 —— 手机是直接跟标签用 NFC 场
// 通信的,不经过设备的 MCU(硬件指南:NTAG213 是被动标签,没有 MCU 侧
// BSP API)。所以这是一个独立能力,不挂在某一台 DeviceSession 下面,
// 界面上也不受"设备有没有连上蓝牙"影响。
//
// 只有 iOS 支持 Core NFC,macOS 编译期直接跳过。模拟器没有 NFC 硬件,
// `NFCNDEFReaderSession.readingAvailable` 在那儿恒为 false —— 必须用
// 真机测试(NFC_TAG=1 ./install-ios.sh,见 tools/gen_ios_project.py)。
// =====================================================================

final class NFCTagIO: NSObject, ObservableObject {
    @Published var lastReadText: String = ""
    @Published var statusText: String = "准备就绪"
    @Published var isBusy = false

    var isSupported: Bool {
        #if os(iOS)
        NFCNDEFReaderSession.readingAvailable
        #else
        false
        #endif
    }

    #if os(iOS)
    /// 非 nil 时这次会话是"写";nil 是"读"。会话结束(成功/失败/取消)后清空。
    private var writePayload: String?
    private var session: NFCNDEFReaderSession?

    func startRead() {
        guard isSupported else {
            statusText = "此设备不支持 NFC(需要真机,模拟器没有 NFC 硬件)"
            return
        }
        writePayload = nil
        beginSession(alert: "把手机靠近设备上的 NFC 标签", invalidateAfterFirstRead: true)
    }

    func startWrite(text: String) {
        guard isSupported else {
            statusText = "此设备不支持 NFC(需要真机,模拟器没有 NFC 硬件)"
            return
        }
        guard !text.isEmpty else {
            statusText = "先输入要写入的内容"
            return
        }
        writePayload = text
        // 写入要在 didDetect(tags:) 里拿到 NFCNDEFTag 才能 connect/write,
        // 所以这里不能 invalidateAfterFirstRead —— 那个开关只影响
        // didDetectNDEFs(纯读消息)那条路径,不影响 tags: 路径,但保持一致
        // 传 false,读写两条路径的会话生命周期由各自的完成回调显式结束。
        beginSession(alert: "把手机靠近要写入的 NFC 标签", invalidateAfterFirstRead: false)
    }

    private func beginSession(alert: String, invalidateAfterFirstRead: Bool) {
        isBusy = true
        statusText = "请把手机靠近标签…"
        let s = NFCNDEFReaderSession(delegate: self, queue: nil,
                                     invalidateAfterFirstRead: invalidateAfterFirstRead)
        s.alertMessage = alert
        session = s
        s.begin()
    }
    #else
    func startRead() { statusText = "NFC 只在 iOS 上支持" }
    func startWrite(text: String) { statusText = "NFC 只在 iOS 上支持" }
    #endif
}

#if os(iOS)
extension NFCTagIO: NFCNDEFReaderSessionDelegate {
    // 协议要求的消息型回调。真正干活的是下面 didDetect(tags:) ——
    // 只有拿到 NFCNDEFTag 句柄才能 connect/查状态/写入,写入路径必须走
    // 那条;这个方法留空,不重复处理。
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: "连接标签失败:\(error.localizedDescription)")
                return
            }
            tag.queryNDEFStatus { status, capacity, error in
                if let error {
                    session.invalidate(errorMessage: "读取标签状态失败:\(error.localizedDescription)")
                    return
                }
                if status == .notSupported {
                    session.invalidate(errorMessage: "这不是一个 NDEF 标签")
                    return
                }
                if let payload = self.writePayload {
                    if status == .readOnly {
                        session.invalidate(errorMessage: "标签是只读的,写不进去")
                        return
                    }
                    self.write(payload, to: tag, capacity: capacity, session: session)
                } else {
                    self.read(tag, session: session)
                }
            }
        }
    }

    private func read(_ tag: NFCNDEFTag, session: NFCNDEFReaderSession) {
        tag.readNDEF { [weak self] message, error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: "读取失败:\(error.localizedDescription)")
                return
            }
            let text = message.flatMap(Self.decodeText) ?? "(标签是空的,或不是文本记录)"
            DispatchQueue.main.async {
                self.lastReadText = text
                self.statusText = "读取成功"
                self.isBusy = false
            }
            session.alertMessage = "读取成功"
            session.invalidate()
        }
    }

    private func write(_ text: String, to tag: NFCNDEFTag, capacity: Int,
                        session: NFCNDEFReaderSession) {
        guard let payload = NFCNDEFPayload.wellKnownTypeTextPayload(
            string: text, locale: Locale(identifier: "zh")) else {
            session.invalidate(errorMessage: "写入内容编码失败")
            return
        }
        let message = NFCNDEFMessage(records: [payload])
        guard message.length <= capacity else {
            session.invalidate(errorMessage: "内容太长(标签容量 \(capacity) 字节,需要 \(message.length) 字节)")
            return
        }
        tag.writeNDEF(message) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: "写入失败:\(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self.statusText = "写入成功"
                self.isBusy = false
            }
            session.alertMessage = "写入成功"
            session.invalidate()
        }
    }

    /// 解析 NDEF 文本记录(RTD_TEXT):第 0 字节是状态位——bit7 = 编码
    /// (0=UTF-8,1=UTF-16),低 6 位 = 语言码长度;之后是语言码,再之后
    /// 才是正文。不是文本记录就退回十六进制,至少能看出标签不是空的。
    private static func decodeText(from message: NFCNDEFMessage) -> String? {
        for record in message.records where record.typeNameFormat == .nfcWellKnown
            && record.type == Data("T".utf8) {
            guard let status = record.payload.first else { continue }
            let langLen = Int(status & 0x3F)
            let isUTF16 = (status & 0x80) != 0
            let textStart = 1 + langLen
            guard record.payload.count >= textStart else { continue }
            let textData = record.payload.suffix(from: textStart)
            let encoding: String.Encoding = isUTF16 ? .utf16 : .utf8
            if let s = String(data: textData, encoding: encoding) { return s }
        }
        guard let first = message.records.first else { return nil }
        let hex = first.payload.map { String(format: "%02x", $0) }.joined()
        return "(非文本记录,payload " + hex + ")"
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async {
            self.isBusy = false
            if let readerError = error as? NFCReaderError,
               readerError.code == .readerSessionInvalidationErrorUserCanceled {
                self.statusText = "已取消"
            } else {
                self.statusText = "失败:\(error.localizedDescription)"
            }
        }
        self.session = nil
        self.writePayload = nil
    }
}

struct NFCToolView: View {
    @StateObject private var model = NFCTagIO()
    @State private var writeText: String = ""

    var body: some View {
        Form {
            Section("状态") {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                if !model.isSupported {
                    Text("此设备不支持 NFC,或者正在模拟器里运行 —— 模拟器没有 NFC 硬件,必须用真机测试。")
                        .font(.caption2).foregroundStyle(.red)
                }
            }

            Section {
                if !model.lastReadText.isEmpty {
                    Text(model.lastReadText)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                Button("读取标签") { model.startRead() }
                    .disabled(model.isBusy || !model.isSupported)
            } header: {
                Text("读取")
            }

            Section {
                TextField("要写入的文本", text: $writeText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("写入标签") { model.startWrite(text: writeText) }
                    .disabled(model.isBusy || !model.isSupported || writeText.isEmpty)
            } header: {
                Text("写入")
            } footer: {
                // 出厂标签上原本写的是什么没有核实过 —— 写入会覆盖原有内容,
                // 覆盖后无法恢复,操作前务必让用户自己确认清楚。
                Text("会覆盖标签上原有的全部内容,写入后无法恢复。请先确认清楚标签上原来写的是什么再操作。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("NFC 标签")
    }
}
#endif
