import Foundation

enum WalkieWire {
    static let protocolVersion: UInt8 = 1
    static let headerSize = 12
    static let maxFrameSize = 92
    static let flagStart: UInt8 = 0x01
    static let flagEnd: UInt8 = 0x02

    static let serviceUUID = "8CC419BC-14D3-462B-88AD-F78E6FDA03F6"
    static let controlUUID = "8CC419BD-14D3-462B-88AD-F78E6FDA03F6"
    static let uplinkUUID = "8CC419BE-14D3-462B-88AD-F78E6FDA03F6"
    static let downlinkUUID = "8CC419BF-14D3-462B-88AD-F78E6FDA03F6"
    static let statusUUID = "8CC419C0-14D3-462B-88AD-F78E6FDA03F6"

    static let controlStart: UInt8 = 1
    static let controlStop: UInt8 = 2

    static let statusReady: UInt8 = 0
    static let statusTxStarted: UInt8 = 1
    static let statusTxStopped: UInt8 = 2
    static let statusError: UInt8 = 3

    static func streamID(in frame: Data) -> UInt16? {
        guard validate(frame) else { return nil }
        return UInt16(frame[2]) | (UInt16(frame[3]) << 8)
    }

    static func hasEnd(_ frame: Data) -> Bool {
        frame.count >= headerSize && frame[1] & flagEnd != 0
    }

    static func hasStart(_ frame: Data) -> Bool {
        frame.count >= headerSize && frame[1] & flagStart != 0
    }

    static func validate(_ frame: Data) -> Bool {
        guard frame.count >= headerSize, frame.count <= maxFrameSize,
              frame[0] == protocolVersion else { return false }
        let samples = Int(frame[6]) | (Int(frame[7]) << 8)
        guard samples <= 160 else { return false }
        let payload = samples > 0 ? samples / 2 : 0
        return frame.count == headerSize + payload
    }
}

struct WalkieRealtimeQueue {
    let limit: Int
    private(set) var frames: [Data] = []

    mutating func enqueue(_ frame: Data) {
        guard limit > 0, WalkieWire.validate(frame) else { return }

        // A START frame defines a new stream. Pending frames from an older
        // stream must not play before it after a reconnect or BLE stall.
        if WalkieWire.hasStart(frame) {
            frames.removeAll(keepingCapacity: true)
        }
        frames.append(frame)

        while frames.count > limit {
            // Preserve stream boundaries whenever possible. Dropping an
            // ordinary audio frame makes a short gap; dropping START/END can
            // leave the receiver in the wrong state until its timeout fires.
            if let stale = frames.firstIndex(where: {
                !WalkieWire.hasStart($0) && !WalkieWire.hasEnd($0)
            }) {
                frames.remove(at: stale)
            } else {
                frames.removeFirst()
            }
        }
    }

    mutating func removeFirst() -> Data {
        frames.removeFirst()
    }

    var count: Int { frames.count }
    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }

    var isEmpty: Bool { frames.isEmpty }
}

struct WalkieControlMessage: Encodable {
    let type: String
    var room: String?
    var name: String?
    var clientId: String?
    var token: String?
    var pushToken: String?
    var stream: UInt16?
}

struct WalkieServerEvent: Decodable {
    let type: String
    var clientId: String?
    var room: String?
    var members: Int?
    var speaker: String?
    var stream: UInt16?
    var message: String?
}

struct WalkieSnapshot: Equatable {
    var installed = false
    var connected = false
    var deviceConnected = false
    var room = "local"
    var members = 0
    var speaker: String?
    /// 正在讲话的那个人的 clientId。**判断「是不是我自己」要用它,不要用
    /// speaker(显示名)** —— 显示名可以重复,默认还都是 "Passport"。
    /// 老服务端不回这个字段,那时它是 nil。
    var speakerId: String?
    var transmitting = false
    var status = "尚未启用"
}
