import Foundation
import CoreBluetooth
#if os(iOS)
import UIKit
#endif

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - BLE Relay

/// Scans for "FoloPassport", connects, discovers the Codex Relay service's two
/// characteristics (DATA for Mac->device pushes, CMD for device->Mac requests),
/// subscribes to CMD, and relays queued (kind, index, total, text) messages using
/// the chunked write protocol described in the task spec. Reconnects indefinitely;
/// never gives up.
final class BLERelay: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let targetName = "FoloPassport"
    // NOTE: on the Swift/CoreBluetooth side we use the UUID strings exactly as given in
    // the spec (standard order) -- the firmware-side BLE_UUID128_INIT byte reversal is a
    // firmware-only concern and does not apply here.
    // Codex service。**只剩 AUDIO 一条还在用**。
    //
    // 这个 service 原本有三个特征值:DATA(电脑 -> 设备,推会话内容)、
    // CMD(设备 -> 电脑,发浏览请求)、AUDIO(设备 -> 电脑,语音流)。
    // 前两条对应的是设备上那套自己浏览会话的界面 —— 架构转向之后,浏览逻辑
    // 整个搬到了 CodexApp,走通用的远程界面通道,那两条就再没有调用方了。
    // 留着一条谁也不写的特征值,只会让下一个读代码的人以为它还在用。
    //
    // AUDIO 不一样:麦克风长在设备上,采样和编码的起点在硬件那一侧,这个
    // 方向没法被远程界面取代。
    static let serviceUUID = CBUUID(string: "7D860E11-CECE-4DC5-85BF-088EBDADC109")
    // Voice-input streaming characteristic (device -> Mac, NOTIFY). String form matches
    // the firmware's BLE_UUID128_INIT byte array (that array is byte-reversed on the
    // NimBLE/firmware side only, per the same convention as the two UUIDs above).
    static let audioCharUUID = CBUUID(string: "0596975F-B995-439C-A41B-3DFA7AA8A81F")

    // App Store service (main/demo_appstore.c) -- a second, fully independent GATT
    // service on the same peripheral. Never advertised at the same time as the Codex
    // service above (the device's VIEW_CODEX/VIEW_APPSTORE state machine guarantees only
    // one of the two BLE stacks runs at once), but discovery is unfiltered (discoverServices(nil)
    // below) so whichever one is actually present just shows up here.
    static let appStoreDataCharUUID = CBUUID(string: "8C2E5A11-6B3D-4F8E-9A1C-2D7E6F4B3A90")
    static let appStoreCmdCharUUID = CBUUID(string: "8C2E5A12-6B3D-4F8E-9A1C-2D7E6F4B3A90")
    /// 设备配置下发(见 main/device_config.c)。收的是 "<key>=<value>\n" 文本行。
    static let deviceConfigCharUUID = CBUUID(string: "9A4C1E21-7F5B-4A3D-8C61-1E9D4B7A2F30")
    /// 设备 -> 这边的状态上报(NOTIFY)。格式跟下发方向一样是 "<key>=<value>\n"。
    /// 配置页上"现在连着哪个 Wi-Fi""扫到了哪些网络"这些事实只有设备知道,
    /// 全靠这条通道。
    static let deviceStatusCharUUID = CBUUID(string: "9A4C1E22-7F5B-4A3D-8C61-1E9D4B7A2F30")
    /// 远程界面(见 main/remote_ui.h)。SCREEN 写屏幕描述,EVENT 收按键。
    static let remoteScreenCharUUID = CBUUID(string: "5D8E3C41-9A72-4B15-8E63-7C4F1A2D9B80")
    static let remoteEventCharUUID  = CBUUID(string: "5D8E3C42-9A72-4B15-8E63-7C4F1A2D9B80")
    /// MANIFEST 写已安装应用清单,设备缓存进 NVS 用来画首屏。
    static let remoteManifestCharUUID = CBUUID(string: "5D8E3C43-9A72-4B15-8E63-7C4F1A2D9B80")
    static let walkieServiceUUID = CBUUID(string: WalkieWire.serviceUUID)
    static let walkieControlCharUUID = CBUUID(string: WalkieWire.controlUUID)
    static let walkieUplinkCharUUID = CBUUID(string: WalkieWire.uplinkUUID)
    static let walkieDownlinkCharUUID = CBUUID(string: WalkieWire.downlinkUUID)
    static let walkieStatusCharUUID = CBUUID(string: WalkieWire.statusUUID)

    // All CoreBluetooth delegate callbacks AND all of this class's mutable state are
    // confined to this single serial queue, so no separate locking is needed.
    private let bleQueue = DispatchQueue(label: "com.folotoy.codexrelay.ble")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?

    private var appStoreDataChar: CBCharacteristic?
    private var deviceConfigChar: CBCharacteristic?
    private var remoteScreenChar: CBCharacteristic?
    private var remoteManifestChar: CBCharacteristic?
    private var walkieControlChar: CBCharacteristic?
    private var walkieUplinkChar: CBCharacteristic?
    private var walkieDownlinkChar: CBCharacteristic?
    private var walkieStatusChar: CBCharacteristic?
    private var walkieAudioQueue = WalkieRealtimeQueue(limit: 12)
    private var walkieUplinkSubscribed = false
    private var walkieStatusSubscribed = false
    /// 还没来得及发出去的清单。RemoteAppHost 在进程启动时就会推一次,那时
    /// 蓝牙多半还没连上;存着,等特征值发现了再补发 —— 否则设备要一直等到
    /// 下一次清单变化才知道装了什么。
    private var pendingManifest: String?

    /// STATUS 通知的拼装缓冲。设备侧尽量在换行处切片,但缓冲装不下一整行时
    /// 会硬切 —— 所以这边不能假设"一个通知就是若干条完整的行",必须自己攒到
    /// 看见换行为止,否则 SSID 长一点的那条状态就会被拆成两半各自解析失败。
    private var statusRxBuffer = ""

    /// 用户在界面上主动点了"断开"。置上之后不再自动重连 —— 少了这个标志,
    /// 点断开会在两秒后被 scheduleReconnect 拉回来,表现为按钮点了没反应。
    private var userDisconnected = false
    private var appStoreCmdChar: CBCharacteristic?

    /// Invoked (on bleQueue) whenever the device sends a CMD request. The handler is
    /// expected to hand off any real work to its own queue immediately so it never
    /// blocks bleQueue / CoreBluetooth callback delivery.

    /// Invoked (on bleQueue) for every AUDIO-characteristic notify packet: (flags,
    /// payload) where payload is everything after the flags byte (may be empty on an
    /// END-only packet). Same contract as onCmdRequest -- the handler must hand off to
    /// its own queue immediately.
    var onAudioChunk: ((UInt8, Data) -> Void)?

    /// Same contract as onCmdRequest, but for the App Store service's CMD characteristic.
    /// Firmware install progress arrives here too (APPSTORE_EVT_PROGRESS, a device-
    /// initiated notification riding the same 3-byte CMD frame, not a real "request") --
    /// see AppStoreModel.handleRequest for why that's the actually-meaningful progress
    /// signal, not anything derived from how fast this process hands writes to
    /// CoreBluetooth.
    var onAppStoreCmdRequest: ((UInt8, UInt8, UInt8) -> Void)?
    /// 远程界面事件(在 bleQueue 上):(evt, a, b)。
    /// evt 0=按键 1=进出远程页 2=设备就绪。见 main/remote_ui.c。
    var onRemoteEvent: ((UInt8, UInt8, UInt8) -> Void)?
    /// 设备上报的状态,已经拆成键值对。
    var onDeviceStatus: (([(String, String)]) -> Void)?
    /// 连接状态变化。第二个参数是设备名(断开时为 nil)。
    var onLinkChange: ((Bool, String?) -> Void)?
    var onWalkieLinkChange: ((Bool) -> Void)?
    var onWalkieAudioFrame: ((Data) -> Void)?
    var onWalkieStatus: ((_ event: UInt8, _ code: UInt8) -> Void)?

    // Outbound message queue waiting to be sent.

    // Chunks (already split, with header bytes) of the message currently in flight.

    // Separate send pipeline for the App Store service -- kept fully independent of the
    // Codex one above (own queue, own in-flight chunk list, own in-flight flag) rather than
    // generalizing the existing pipeline to take a target characteristic, specifically so
    // this addition can't regress the already-verified Codex send path. The one real
    // difference from Codex's pipeline: payload here is raw `Data` (firmware bytes can
    // contain any byte value, including embedded NULs and invalid UTF-8), never a `String`.
    private var appStoreMessageQueue: [(kind: UInt8, index: UInt16, total: UInt16, payload: Data)] = []
    private var appStoreChunkQueue: [Data] = []
    private var appStoreWaitingForWriteCallback = false

    func start() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.central = CBCentralManager(
                delegate: self,
                queue: self.bleQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey:
                          "com.folotoy.codexrelay.central"]
            )
            #if os(iOS)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                self?.bleQueue.async { self?.restartScanForCurrentState() }
            }
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                self?.bleQueue.async { self?.restartScanForCurrentState() }
            }
            #endif
            self.scheduleWatchdog()
        }
    }

    /// Thread-safe entry point for the App Store model to hand off a message (catalog
    /// item or a firmware chunk) -- same contract as enqueue() above, separate queue.
    func enqueueAppStore(kind: UInt8, index: UInt16, total: UInt16, payload: Data) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.appStoreMessageQueue.append((kind, index, total, payload))
            self.pumpAppStore()
        }
    }

    /// Entry point for AppStoreModel to abandon a firmware transfer immediately (device
    /// reported APPSTORE_EVT_INSTALL_ABORTED) instead of grinding through however many
    /// thousands of already-enqueued chunks remain -- the device has already stopped
    /// listening to them.
    func cancelAppStoreTransfer() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            let dropped = self.appStoreMessageQueue.count + (self.appStoreChunkQueue.isEmpty ? 0 : 1)
            self.appStoreMessageQueue.removeAll()
            self.appStoreChunkQueue.removeAll()
            log("应用商店:收到设备中止通知,丢弃 \(dropped) 条待发消息")
        }
    }

    /// Lets AppStoreModel pre-slice a firmware file into pieces that are each guaranteed
    /// to become exactly one on-wire chunk (never further split by buildAppStoreChunks),
    /// so the index/total it sends is real per-packet progress, not just a logical count
    /// that could silently diverge from actual wire chunks if the negotiated MTU were
    /// smaller than assumed. Synchronous and safe to call from any queue (peripheral's
    /// maximumWriteValueLength is just a stored property read, not a round-trip).
    /// ⚠ Must be the MINIMUM of both write types, not just .withResponse. Catalog items go
    /// out via pumpAppStore() as .withResponse (limit 512, the ATT long-write ceiling)
    /// while firmware chunks go out via drainAppStoreBatch() as .withoutResponse (limit is
    /// the negotiated MTU minus 3 -- typically ~250, i.e. HALF). CoreBluetooth SILENTLY
    /// DISCARDS a .withoutResponse write that exceeds its own limit: no thrown error, no
    /// didWriteValueFor callback, nothing delivered, nothing logged. Sizing chunks off the
    /// .withResponse limit alone made every single firmware chunk oversized, so the entire
    /// install went out into the void -- the device never received one byte, never sent a
    /// progress ack, and the transfer looked exactly like a hang with zero diagnostics.
    func appStoreMaxPayloadSize() -> Int {
        guard let p = peripheral else { return max(23 - 6, 1) }
        let maxLen = min(p.maximumWriteValueLength(for: .withResponse),
                         p.maximumWriteValueLength(for: .withoutResponse))
        return max(maxLen - 6, 1)
    }

    // MARK: Connection lifecycle

    private func startScanIfNeeded() {
        guard central != nil, central.state == .poweredOn else { return }
        guard peripheral == nil else { return } // already discovered; reconnect path handles it
        log("开始扫描 \(Self.targetName) ...")
        #if os(iOS)
        // Background discovery only wakes for explicitly requested services.
        // Foreground scanning remains unfiltered so the companion can still
        // discover older firmware and upgrade it to the walkie-capable build.
        let services: [CBUUID]? = UIApplication.shared.applicationState == .background
            ? [Self.walkieServiceUUID] : nil
        #else
        let services: [CBUUID]? = nil
        #endif
        central.scanForPeripherals(withServices: services, options: nil)
    }

    private func restartScanForCurrentState() {
        guard central != nil, central.state == .poweredOn, peripheral == nil else { return }
        central.stopScan()
        startScanIfNeeded()
    }

    /// Safety net: periodically make sure we are scanning if we've never found the
    /// device yet. Cheap and idempotent (scanForPeripherals is a no-op if already
    /// scanning), so this is a harmless belt-and-suspenders check.
    private func scheduleWatchdog() {
        bleQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            self.startScanIfNeeded()
            self.scheduleWatchdog()
        }
    }

    private func scheduleReconnect(to peripheral: CBPeripheral) {
        bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            guard self.central.state == .poweredOn else { return } // watchdog will catch it later
            log("尝试重新连接 \(Self.targetName) ...")
            self.central.connect(peripheral, options: nil)
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("蓝牙状态变化: \(c.state.rawValue) (5=poweredOn)")
        switch c.state {
        case .poweredOn:
            startScanIfNeeded()
        default:
            // Not usable right now (off/unauthorized/unsupported/resetting/unknown).
            // Do NOT exit -- this is a long-lived relay; the watchdog will resume
            // scanning automatically once the state becomes poweredOn again.
            //
            // ⚠ 这里以前只清了三个特征值,留下 peripheral 和另外三个不动,
            // 也不通知任何人。后果有三个,都不报错:
            //   1. onLinkChange 不发 false —— 界面继续显示"已连接",而链路
            //      已经死了(didDisconnectPeripheral 在关蓝牙这条路上未必来);
            //   2. sendRemoteManifest 看到 peripheral 和 remoteManifestChar
            //      都非 nil,就绕过 pendingManifest 直接往死链路写,被无声
            //      丢弃、而且不会补发;
            //   3. startScanIfNeeded 看到 peripheral != nil 提前返回,
            //      看门狗也救不回来。
            // 一并清干净,并且如实广播"断了"。
            let wasLinked = peripheral != nil
            peripheral = nil
            audioChar = nil
            appStoreDataChar = nil
            appStoreCmdChar = nil
            walkieControlChar = nil
            walkieUplinkChar = nil
            walkieDownlinkChar = nil
            walkieStatusChar = nil
            walkieUplinkSubscribed = false
            walkieStatusSubscribed = false
            walkieAudioQueue.removeAll()
            onWalkieLinkChange?(false)
            deviceConfigChar = nil
            remoteScreenChar = nil
            remoteManifestChar = nil
            if wasLinked { onLinkChange?(false, nil) }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        #if os(iOS)
        // Background scans are already filtered by the unique walkie service.
        // iOS may omit the local name from background advertisements, so do
        // not reject the only matching peripheral merely because name is nil.
        let serviceMatched = UIApplication.shared.applicationState == .background
        guard serviceMatched || name == Self.targetName else { return }
        #else
        guard name == Self.targetName else { return }
        #endif
        log("发现设备: \(name.isEmpty ? Self.targetName : name) rssi=\(RSSI)")
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("已连接 \(Self.targetName),开始发现服务...")
        p.delegate = self
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("连接失败: \(String(describing: error)),将自动重试")
        scheduleReconnect(to: p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log(userDisconnected ? "设备已按用户要求断开"
                             : "设备已断开连接: \(String(describing: error)),将自动重连")
        onLinkChange?(false, nil)
        statusRxBuffer = ""
        audioChar = nil
        appStoreDataChar = nil
        appStoreCmdChar = nil
        deviceConfigChar = nil
        remoteScreenChar = nil
        remoteManifestChar = nil
        walkieControlChar = nil
        walkieUplinkChar = nil
        walkieDownlinkChar = nil
        walkieStatusChar = nil
        walkieUplinkSubscribed = false
        walkieStatusSubscribed = false
        walkieAudioQueue.removeAll()
        onWalkieLinkChange?(false)
        appStoreWaitingForWriteCallback = false
        appStoreChunkQueue.removeAll()
        pendingBatchResume = nil
        pendingBatchResumeToken &+= 1
        // 用户主动断开的话就停在这里,等他点"重新扫描"。
        if !userDisconnected { scheduleReconnect(to: p) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = restored.first else { return }
        peripheral = p
        p.delegate = self
        if p.state == .connected {
            p.discoverServices(nil)
        } else {
            central.connect(p, options: nil)
        }
        log("恢复 BLE 外设状态:\(p.identifier)")
    }

    // MARK: 供界面调用的连接控制

    /// 用户点了"断开"。
    func disconnectDevice() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.userDisconnected = true
            if let p = self.peripheral {
                self.central.cancelPeripheralConnection(p)
            }
        }
    }

    /// 用户点了"重新扫描":解除断开状态,忘掉当前这台,重新扫。
    func rescanDevice() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.userDisconnected = false
            if let p = self.peripheral, self.deviceConfigChar != nil {
                // 还连着就先断开 —— 不然 scanForPeripherals 找不到一台已经
                // 连上的设备,点了"重新扫描"会像什么都没发生。
                self.central.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
            self.startScanIfNeeded()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("发现服务出错: \(error)")
            return
        }
        for svc in p.services ?? [] {
            log("发现 service: \(svc.uuid)")
            p.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if let error = error {
            log("发现特征值出错: \(error)")
            return
        }
        for chr in svc.characteristics ?? [] {
            log("发现 characteristic: \(chr.uuid) properties=\(chr.properties)")
            if chr.uuid == Self.audioCharUUID {
                audioChar = chr
                log("发现 AUDIO characteristic,订阅 notify...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.appStoreDataCharUUID {
                appStoreDataChar = chr
                log("应用商店 DATA characteristic 就绪,可以开始发送消息")
                pumpAppStore()
            } else if chr.uuid == Self.appStoreCmdCharUUID {
                appStoreCmdChar = chr
                log("发现应用商店 CMD characteristic,订阅 indicate...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.deviceConfigCharUUID {
                deviceConfigChar = chr
                log("设备配置 characteristic 就绪")
                // 配置特征值就绪 = 这条链路真的能用了。onLinkChange 同时带上
                // 设备名,界面上要显示"已连接 FoloPassport"而不只是一个绿点。
                onLinkChange?(true, p.name)
            } else if chr.uuid == Self.deviceStatusCharUUID {
                log("发现设备状态 characteristic,订阅 notify...")
                statusRxBuffer = ""
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.remoteScreenCharUUID {
                remoteScreenChar = chr
                log("远程界面 SCREEN characteristic 就绪")
            } else if chr.uuid == Self.remoteManifestCharUUID {
                remoteManifestChar = chr
                log("远程界面 MANIFEST characteristic 就绪")
                if let pending = pendingManifest {
                    pendingManifest = nil
                    writeManifest(pending, to: chr, on: p)
                }
            } else if chr.uuid == Self.remoteEventCharUUID {
                log("发现远程界面 EVENT characteristic,订阅 indicate...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.walkieControlCharUUID {
                walkieControlChar = chr
                log("发现对讲 CONTROL characteristic")
            } else if chr.uuid == Self.walkieUplinkCharUUID {
                walkieUplinkChar = chr
                log("发现对讲 UPLINK characteristic,订阅 notify...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.walkieDownlinkCharUUID {
                walkieDownlinkChar = chr
                log("发现对讲 DOWNLINK characteristic")
                drainWalkieAudio()
            } else if chr.uuid == Self.walkieStatusCharUUID {
                walkieStatusChar = chr
                log("发现对讲 STATUS characteristic,订阅 notify...")
                p.setNotifyValue(true, for: chr)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor chr: CBCharacteristic, error: Error?) {
        guard chr.uuid == Self.audioCharUUID
              || chr.uuid == Self.appStoreCmdCharUUID
              || chr.uuid == Self.remoteEventCharUUID
              || chr.uuid == Self.deviceStatusCharUUID
              || chr.uuid == Self.walkieUplinkCharUUID
              || chr.uuid == Self.walkieStatusCharUUID else { return }
        if let error = error {
            // Not retried specially -- the existing watchdog/reconnect machinery will
            // naturally get us a fresh connection (and a fresh subscribe attempt) later.
            log("订阅 \(chr.uuid) 特征值失败: \(error)")
            return
        }
        log("\(chr.uuid) 特征值订阅状态: isNotifying=\(chr.isNotifying)")
        if chr.uuid == Self.walkieUplinkCharUUID {
            walkieUplinkSubscribed = chr.isNotifying
        } else if chr.uuid == Self.walkieStatusCharUUID {
            walkieStatusSubscribed = chr.isNotifying
        }
        publishWalkieLinkState()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor chr: CBCharacteristic, error: Error?) {
        if chr.uuid == Self.audioCharUUID {
            if let error = error {
                log("AUDIO 特征值更新出错: \(error)")
                return
            }
            guard let value = chr.value, !value.isEmpty else {
                log("收到空的 AUDIO 分片(连 flags 字节都没有),忽略")
                return
            }
            let flags = value[value.startIndex]
            let payload = value.count > 1 ? value.subdata(in: value.index(after: value.startIndex)..<value.endIndex) : Data()
            onAudioChunk?(flags, payload)
            return
        }
        if chr.uuid == Self.walkieUplinkCharUUID {
            guard error == nil, let frame = chr.value, WalkieWire.validate(frame) else { return }
            onWalkieAudioFrame?(frame)
            return
        }
        if chr.uuid == Self.walkieStatusCharUUID {
            guard error == nil, let data = chr.value, data.count >= 3,
                  data[0] == WalkieWire.protocolVersion else { return }
            onWalkieStatus?(data[1], data[2])
            return
        }
        if chr.uuid == Self.deviceStatusCharUUID {
            if let error = error {
                log("设备状态更新出错: \(error)")
                return
            }
            guard let v = chr.value, let text = String(data: v, encoding: .utf8) else { return }
            statusRxBuffer += text
            // 只处理已经完整收到的行,残缺的最后一段留在缓冲里等下一个通知。
            var pairs: [(String, String)] = []
            while let nl = statusRxBuffer.firstIndex(of: "\n") {
                let line = String(statusRxBuffer[statusRxBuffer.startIndex..<nl])
                statusRxBuffer = String(statusRxBuffer[statusRxBuffer.index(after: nl)...])
                // 只按**第一个** '=' 切:值里可能还有 '='(比如某些 SSID)。
                guard let eq = line.firstIndex(of: "=") else { continue }
                pairs.append((String(line[line.startIndex..<eq]),
                              String(line[line.index(after: eq)...])))
            }
            // 缓冲失控保护:设备要是发了一大段没有换行的东西,不能让它无限增长。
            if statusRxBuffer.utf8.count > 4096 {
                log("设备状态缓冲超长,丢弃")
                statusRxBuffer = ""
            }
            if !pairs.isEmpty { onDeviceStatus?(pairs) }
            return
        }
        if chr.uuid == Self.remoteEventCharUUID {
            if let error = error {
                log("远程界面 EVENT 更新出错: \(error)")
                return
            }
            guard let v = chr.value, v.count >= 3 else { return }
            let b = [UInt8](v)
            onRemoteEvent?(b[0], b[1], b[2])
            return
        }
        if chr.uuid == Self.appStoreCmdCharUUID {
            if let error = error {
                log("应用商店 CMD 特征值更新出错: \(error)")
                return
            }
            guard let value = chr.value else { return }
            let bytes = [UInt8](value)
            guard bytes.count >= 3 else {
                log("收到的应用商店 CMD 请求长度不足,忽略: \(bytes.count) 字节")
                return
            }
            log("收到应用商店 CMD 请求: req=\(bytes[0]) a=\(bytes[1]) b=\(bytes[2])")
            onAppStoreCmdRequest?(bytes[0], bytes[1], bytes[2])
            return
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor chr: CBCharacteristic, error: Error?) {
        // ⚠ 必须**按 UUID 精确分派**,不能写成"是应用商店就 A,否则 B"。
        //
        // 这个回调对**每一个** .withResponse 写入都会触发。只有应用商店 DATA
        // 那一条有分片队列需要推进;配置下发、远程推屏、清单推送也都是
        // .withResponse 的,但它们整段一次写完,没有队列。
        //
        // 早先这里写的是"是应用商店就 A,否则 B",于是后三者的完成回调会被
        // 当成分片完成,把别人的流水线推着往前走 —— 表现为内容偶尔缺一段,
        // 而且只在两条路径恰好撞上时才出现,极难复现。按 UUID 精确分派之后
        // 这类串台在结构上就不可能发生了。
        switch chr.uuid {
        case Self.appStoreDataCharUUID:
            appStoreWaitingForWriteCallback = false
            if let error = error {
                log("应用商店写入出错: \(error),丢弃当前消息剩余分片")
                appStoreChunkQueue.removeAll()
            }
            pumpAppStore()

        default:
            // 配置 / 推屏 / 清单:整段一次写完,没有分片队列要推进。
            // 出错值得记一笔(否则界面上会表现为"下发了但设备没反应"),
            // 但绝不能碰上面两条流水线的状态。
            if let error = error {
                log("写入 \(chr.uuid) 出错: \(error)")
            }
        }
    }

    /// CoreBluetooth's local send-buffer had no room the last time
    /// drainAppStoreBatch() tried to write -- resume from exactly where it left off.
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if let resume = pendingBatchResume {
            pendingBatchResume = nil
            pendingBatchResumeToken &+= 1
            resume()
        }
        drainWalkieAudio()
    }

    // MARK: Send pipeline

    /// Drives the send state machine. Must only be called on bleQueue.
    /// App Store equivalent of pump() -- separate queue/characteristic, same state
    /// machine shape. Must only be called on bleQueue.
    private func pumpAppStore() {
        guard let p = peripheral, let chr = appStoreDataChar else { return }
        guard !appStoreWaitingForWriteCallback else { return }

        if appStoreChunkQueue.isEmpty {
            guard !appStoreMessageQueue.isEmpty else { return }
            let msg = appStoreMessageQueue.removeFirst()
            let maxLen = p.maximumWriteValueLength(for: .withResponse)
            let payloadSize = max(maxLen - 6, 1)
            appStoreChunkQueue = Self.buildAppStoreChunks(kind: msg.kind, index: msg.index,
                                                          total: msg.total, payload: msg.payload,
                                                          payloadSize: payloadSize)
            // This queue/pump pair now only ever carries kind=item messages (a handful
            // per REQ_LIST_APPS, never more) -- firmware transfer bypasses it entirely
            // via sendAppStoreBatch(withoutResponse:) below, so logging every message
            // here is cheap and fine.
            log("应用商店:开始发送消息 kind=\(msg.kind) index=\(msg.index) total=\(msg.total) 分片数=\(appStoreChunkQueue.count) payloadSize=\(payloadSize) 字节数=\(msg.payload.count)")
        }

        guard !appStoreChunkQueue.isEmpty else { return }
        let chunk = appStoreChunkQueue.removeFirst()
        appStoreWaitingForWriteCallback = true
        p.writeValue(chunk, for: chr, type: .withResponse)
    }

    /// Data-based equivalent of buildChunks() below -- no String/UTF-8 involved, since
    /// firmware bytes (kind=firmware) can contain any byte value including embedded NULs
    /// and sequences that aren't valid UTF-8. Catalog item text (kind=item) is also sent
    /// through this path, pre-encoded to UTF-8 Data by the caller. Chunk boundaries can
    /// fall anywhere -- there's no multi-byte-character concern for raw binary data.
    ///
    /// `index`/`total` mean two DIFFERENT things depending on `kind`, and the START/END
    /// flags must be computed accordingly -- getting this wrong is what caused every
    /// firmware chunk to be independently esp_ota_begin()/esp_ota_end()'d on the device
    /// (main/demo_appstore.c), re-erasing the whole partition and finalizing a ~500-byte
    /// "image" on literally every single chunk:
    /// - kind=item: index/total = "which catalog entry, out of how many" -- each entry is
    ///   its own independent message that the device reassembles separately (its own
    ///   START clears the accumulator, its own END dispatches it). Payload-position-based
    ///   flags (the original logic) are correct here.
    /// - kind=firmware: index/total = "which piece of ONE continuous multi-thousand-chunk
    ///   stream, out of how many total". AppStoreModel.installApp() already pre-slices
    ///   each piece to fit in a single wire packet, so from a payload-position view every
    ///   single piece trivially looks like both the start AND end of "its own message" --
    ///   exactly the bug. START/END must instead reflect position in the OVERALL stream:
    ///   only global chunk 0 is START, only global chunk (total-1) is END.
    static func buildAppStoreChunks(kind: UInt8, index: UInt16, total: UInt16, payload: Data,
                                    payloadSize: Int) -> [Data] {
        let isStreamPiece = (kind == AppStoreKind.firmware)

        if payload.isEmpty {
            let isFirst = !isStreamPiece || index == 0
            let isLast = !isStreamPiece || index == total - 1
            var flags: UInt8 = 0
            if isFirst { flags |= RelayFlags.start }
            if isLast { flags |= RelayFlags.end }
            let data = Data([flags, kind,
                             UInt8(index & 0xFF), UInt8(index >> 8),
                             UInt8(total & 0xFF), UInt8(total >> 8)])
            return [data]
        }

        var chunks: [Data] = []
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let end = payload.index(offset, offsetBy: payloadSize, limitedBy: payload.endIndex) ?? payload.endIndex
            let isFirstFragment = (offset == payload.startIndex)
            let isLastFragment = (end == payload.endIndex)
            var flags: UInt8 = 0
            let isStart = isStreamPiece ? (index == 0 && isFirstFragment) : isFirstFragment
            let isEnd = isStreamPiece ? (index == total - 1 && isLastFragment) : isLastFragment
            if isStart { flags |= RelayFlags.start }
            if isEnd { flags |= RelayFlags.end }
            var data = Data([flags, kind,
                             UInt8(index & 0xFF), UInt8(index >> 8),
                             UInt8(total & 0xFF), UInt8(total >> 8)])
            data.append(payload[offset..<end])
            chunks.append(data)
            offset = end
        }
        return chunks
    }

    // MARK: App Store firmware batch transfer (write without response)

    /// Queued once a caller asks to send a batch while CoreBluetooth's local send buffer
    /// is full; resumed from peripheral(_:isReadyToSendWriteWithoutResponse:).
    private var pendingBatchResume: (() -> Void)?
    /// Identifies WHICH wait `pendingBatchResume` currently holds. Bumped every time that
    /// slot is filled or consumed, so a late fallback timer can tell "the wait I was armed
    /// for" apart from "some newer wait that happens to be pending now" -- see the comment
    /// in drainAppStoreBatch for the transfer-stalling bug this prevents.
    private var pendingBatchResumeToken: UInt64 = 0

    /// Sends `chunks` (already fully framed by AppStoreModel via buildAppStoreChunks) as
    /// write-without-response, respecting CoreBluetooth's local flow control
    /// (canSendWriteWithoutResponse) instead of waiting for a per-chunk ATT response --
    /// that per-chunk round trip is what made a firmware install take 10+ minutes despite
    /// a healthy link. Unlike pump()/pumpAppStore(), this does NOT wait for the device to
    /// confirm anything; AppStoreModel handles that at a higher level via the
    /// APPSTORE_EVT_PROGRESS batch-acknowledgment protocol (see its sendNextBatch()),
    /// which is also what makes retrying a batch safe (the device skips chunks it has
    /// already written, so resending is idempotent).
    ///
    /// `completion` fires once every chunk in the batch has been handed to CoreBluetooth
    /// -- that only means "accepted for transmission locally", not "delivered", exactly
    /// like the flow-control contract write-without-response always has.
    func sendAppStoreBatch(withoutResponse chunks: [Data], completion: @escaping () -> Void) {
        bleQueue.async { [weak self] in
            self?.drainAppStoreBatch(chunks, from: 0, completion: completion)
        }
    }

    /// 下发一批配置项。每项一行 "<key>=<value>",一次写完。
    ///
    /// 用 .withResponse:配置是低频小数据,可靠性远比吞吐重要,而且写失败时
    /// didWriteValueFor 会带错误回来 —— 用户在界面上点了"保存"就该知道到底
    /// 存没存上,不能像固件分片那样"发出去就算数"。
    func sendDeviceConfig(_ pairs: [(String, String)], completion: @escaping (Bool) -> Void) {
        bleQueue.async { [weak self] in
            guard let self = self, let p = self.peripheral, let chr = self.deviceConfigChar else {
                log("设备配置:没有可用的连接")
                completion(false)
                return
            }
            let text = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else { completion(false); return }
            // 设备端缓冲区 512 字节,超了会被截断 —— 分批发,不要指望对端兜底。
            let maxLen = min(p.maximumWriteValueLength(for: .withResponse), 500)
            var offset = 0
            while offset < data.count {
                let end = min(offset + maxLen, data.count)
                p.writeValue(data.subdata(in: offset..<end), for: chr, type: .withResponse)
                offset = end
            }
            log("设备配置:已下发 \(pairs.count) 项")
            completion(true)
        }
    }

    /// 推一屏内容给设备。设备靠结尾的换行判断收齐,所以拆包发送时不能在
    /// 中间截断 —— 这里整段一次写,超过 MTU 的部分由 CoreBluetooth 自己分片,
    /// 设备侧会攒到看见换行为止。
    func sendRemoteScreen(_ text: String) {
        bleQueue.async { [weak self] in
            guard let self = self, let p = self.peripheral,
                  let chr = self.remoteScreenChar else { return }
            guard let data = text.data(using: .utf8) else { return }
            // 设备接收缓冲 1KB;超了它会整屏丢弃,与其那样不如这里就截断到
            // 最后一个完整行,至少还能显示前半屏。
            var payload = data
            if payload.count > 1000 {
                let head = payload.prefix(1000)
                if let lastNewline = head.lastIndex(of: 0x0A) {
                    payload = Data(head[...lastNewline])
                } else {
                    payload = Data(head)
                }
                log("远程界面:内容过长已截断到 \(payload.count) 字节")
            }
            let maxLen = min(p.maximumWriteValueLength(for: .withResponse), 500)
            var offset = 0
            while offset < payload.count {
                let end = min(offset + maxLen, payload.count)
                p.writeValue(payload.subdata(in: offset..<end), for: chr, type: .withResponse)
                offset = end
            }
        }
    }

    /// 推已安装应用清单给设备(一行一个名字,结尾必须有换行)。
    func sendRemoteManifest(_ text: String) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard let p = self.peripheral, let chr = self.remoteManifestChar else {
                // 连接还没建立/特征值还没发现,先记着。只保留最新的一份 ——
                // 清单是全量覆盖语义,补发中间某个旧版本没有意义。
                self.pendingManifest = text
                return
            }
            self.writeManifest(text, to: chr, on: p)
        }
    }

    func sendWalkieControl(operation: UInt8, stream: UInt16) {
        bleQueue.async { [weak self] in
            guard let self, let p = self.peripheral, let chr = self.walkieControlChar else {
                return
            }
            let payload = Data([
                WalkieWire.protocolVersion, operation,
                UInt8(stream & 0xff), UInt8(stream >> 8),
            ])
            p.writeValue(payload, for: chr, type: .withResponse)
        }
    }

    func sendWalkieAudio(_ frame: Data) {
        guard WalkieWire.validate(frame) else { return }
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.walkieAudioQueue.enqueue(frame)
            self.drainWalkieAudio()
        }
    }

    private func drainWalkieAudio() {
        guard let p = peripheral, let chr = walkieDownlinkChar else { return }
        while !walkieAudioQueue.isEmpty && p.canSendWriteWithoutResponse {
            let frame = walkieAudioQueue.removeFirst()
            guard frame.count <= p.maximumWriteValueLength(for: .withoutResponse) else {
                log("对讲音频帧超过当前 BLE MTU,已丢弃:\(frame.count) 字节")
                continue
            }
            p.writeValue(frame, for: chr, type: .withoutResponse)
        }
    }

    private func publishWalkieLinkState() {
        let ready = peripheral?.state == .connected &&
            walkieControlChar != nil && walkieDownlinkChar != nil &&
            walkieUplinkSubscribed && walkieStatusSubscribed
        onWalkieLinkChange?(ready)
    }

    /// Must only be called on bleQueue.
    private func writeManifest(_ text: String, to chr: CBCharacteristic, on p: CBPeripheral) {
        guard var payload = text.data(using: .utf8) else { return }
        // 设备侧缓冲 512 字节,超了它整份丢弃。截到最后一个完整行,至少前
        // 几个应用还能出现在首屏。留 1 字节给下面补回的哨兵换行。
        if payload.count > 499 {
            let head = payload.prefix(499)
            if let lastNewline = head.lastIndex(of: 0x0A) {
                // ⚠ 截断后必须把哨兵补回来:设备等的是空行(连着两个换行)。
                // 截到行尾只留下一个换行,设备会一直等下去,首屏永远不更新。
                payload = Data(head[...lastNewline]) + Data([0x0A])
            } else {
                // 一个换行都没有,发过去设备也凑不齐一份完整清单,不如不发。
                log("远程界面:清单格式异常(没有换行),丢弃")
                return
            }
            log("远程界面:清单过长已截断到 \(payload.count) 字节")
        }
        // 这里分包发是正常的 —— iOS 的 ATT MTU 只有 185,一份满清单必然
        // 拆成几包。设备靠结尾的空行判断收齐,不靠包边界。
        let maxLen = max(p.maximumWriteValueLength(for: .withResponse), 1)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxLen, payload.count)
            p.writeValue(payload.subdata(in: offset..<end), for: chr, type: .withResponse)
            offset = end
        }
    }

    /// Must only be called on bleQueue.
    private func drainAppStoreBatch(_ chunks: [Data], from start: Int, completion: @escaping () -> Void) {
        guard let p = peripheral, let chr = appStoreDataChar else {
            log("应用商店:没有可用的连接,放弃发送这一批(共 \(chunks.count) 片)")
            completion()
            return
        }
        var i = start
        while i < chunks.count {
            guard p.canSendWriteWithoutResponse else {
                // Don't rely solely on peripheralIsReady(toSendWriteWithoutResponse:) to
                // ever fire -- this Mac's Bluetooth stack has been flaky all session
                // (repeated resets, mystery slowness), and that delegate callback has
                // never actually been exercised here before now. If it silently never
                // arrives, the batch (and everything after it, since the retry-timeout
                // is only ever armed inside this call's completion) would hang forever
                // with zero further log output -- exactly what happened on the first
                // real test of this path. A short fallback poll guarantees forward
                // progress either way; whichever of the two fires first consumes
                // pendingBatchResume and the other becomes a no-op.
                let resume: () -> Void = { [weak self] in
                    self?.drainAppStoreBatch(chunks, from: i, completion: completion)
                }
                pendingBatchResume = resume
                pendingBatchResumeToken &+= 1
                let myToken = pendingBatchResumeToken
                bleQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    // ⚠ 必须校验令牌,不能只判断 pendingBatchResume 非空。常见时序是:
                    // 真正的流控回调先一步(比如 50ms)恢复并发完了这一批,上层收到
                    // 回执又发下一批、下一批也挂起等待 —— 此时槽位里放的已经是新
                    // 批次的恢复闭包了。这个迟到的定时器若只看"非空",就会把新批次
                    // 的等待清掉、转而重发上一批已经发完的内容:新批次从此永久停摆
                    // (只发出去了挂起前的那几片),旧内容变成重复分片让设备补报一个
                    // 只前进 1 的确认号,整批只能靠 5 秒超时重发才走完 —— 实测每一批
                    // 都卡满一个超时周期,比不批量还慢。
                    guard let self = self, self.pendingBatchResumeToken == myToken,
                          self.pendingBatchResume != nil else { return }
                    self.pendingBatchResume = nil
                    self.pendingBatchResumeToken &+= 1
                    resume()
                }
                return
            }
            p.writeValue(chunks[i], for: chr, type: .withoutResponse)
            i += 1
        }
        completion()
    }

}
