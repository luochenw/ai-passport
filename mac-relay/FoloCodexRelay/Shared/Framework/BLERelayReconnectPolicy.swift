import Foundation

/// The user-visible name of this companion installation. It is intentionally
/// independent from the operating-system device name: a fresh install starts
/// from a predictable, private label and only exposes what the user chooses.
enum CompanionNamePolicy {
    static let defaultsKey = "auth.companion-name.v1"
    static let maxUTF8Bytes = 48

    static var platformDefault: String {
        #if os(iOS)
        return "我的 iPhone"
        #else
        return "我的 Mac"
        #endif
    }

    /// Remove protocol control characters while preserving ordinary Unicode.
    /// The UI applies this on every edit, and validation repeats the check so a
    /// caller outside SwiftUI cannot smuggle a delimiter into COMMAND/HELLO.
    static func sanitized(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            $0.value != 0x2028 && $0.value != 0x2029
        })
    }

    static func normalized(_ value: String) -> String {
        sanitized(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validationMessage(for value: String) -> String? {
        let normalized = normalized(value)
        guard !normalized.isEmpty else { return "名称不能为空。" }
        guard normalized.utf8.count <= maxUTF8Bytes else {
            return "名称最多 48 个 UTF-8 字节（中文通常占 3 字节）。"
        }
        return nil
    }

    static func load(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: defaultsKey),
           validationMessage(for: stored) == nil,
           normalized(stored) == stored {
            return stored
        }
        let value = platformDefault
        defaults.set(value, forKey: defaultsKey)
        return value
    }

    @discardableResult
    static func save(_ value: String, defaults: UserDefaults = .standard) -> Bool {
        let normalized = normalized(value)
        guard validationMessage(for: normalized) == nil else { return false }
        defaults.set(normalized, forKey: defaultsKey)
        return true
    }
}

/// Pure COMMAND encoder. Keeping the byte limits out of CoreBluetooth makes
/// the no-truncation rule testable on macOS and in CI.
enum CompanionAuthCommandWire {
    static func payload(operation: UInt8, value: String) -> Data? {
        let limit: Int
        switch operation {
        case 0x01: limit = 32
        case 0x08: limit = CompanionNamePolicy.maxUTF8Bytes
        default: limit = 64
        }
        if operation == 0x08 {
            guard CompanionNamePolicy.validationMessage(for: value) == nil,
                  CompanionNamePolicy.normalized(value) == value else { return nil }
        }
        let bytes = Data(value.utf8)
        guard bytes.count <= limit else { return nil }
        var result = Data([operation])
        result.append(bytes)
        return result
    }
}

/// One newline-delimited authentication STATE field. Values are split on the
/// first `=` only; percent decoding happens after framing so encoded delimiters
/// remain data.
struct CompanionAuthStateLine: Equatable {
    let key: String
    let rawValue: String
    let value: String

    static func parse(_ line: String) -> CompanionAuthStateLine? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<separator])
        guard !key.isEmpty else { return nil }
        let raw = String(line[line.index(after: separator)...])
        return CompanionAuthStateLine(key: key, rawValue: raw,
                                      value: raw.removingPercentEncoding ?? raw)
    }
}

/// Splits the legacy newline-terminated remote-screen stream without changing
/// its framing. Older firmware commits a screen whenever a write ends in LF,
/// so only the final write may have LF as its last byte.
enum RemoteScreenChunker {
    static func chunks(_ text: String, payloadLimit: Int = 1000,
                       chunkLimit: Int) -> [Data]? {
        guard payloadLimit > 0, chunkLimit >= 5 else { return nil }

        var payload = Data()
        var scalarBoundaries = [0]
        var lastNewlineBoundary: Int?
        var truncated = false
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            guard payload.count + bytes.count <= payloadLimit else {
                truncated = true
                break
            }
            payload.append(bytes)
            scalarBoundaries.append(payload.count)
            if scalar.value == 0x0A { lastNewlineBoundary = payload.count }
        }
        if truncated, let newline = lastNewlineBoundary {
            payload = Data(payload.prefix(newline))
            scalarBoundaries.removeAll { $0 > newline }
        }
        guard !payload.isEmpty else { return [] }

        var result: [Data] = []
        var boundaryIndex = 0
        while boundaryIndex < scalarBoundaries.count - 1 {
            let offset = scalarBoundaries[boundaryIndex]
            var endIndex = boundaryIndex + 1
            while endIndex + 1 < scalarBoundaries.count,
                  scalarBoundaries[endIndex + 1] - offset <= chunkLimit {
                endIndex += 1
            }
            guard scalarBoundaries[endIndex] - offset <= chunkLimit else { return nil }

            let isFinal = endIndex == scalarBoundaries.count - 1
            if !isFinal {
                // Shift any boundary LF into the next write. We only move at
                // scalar boundaries, so a multibyte code point is never split.
                while endIndex > boundaryIndex,
                      payload[scalarBoundaries[endIndex] - 1] == 0x0A {
                    endIndex -= 1
                }
                guard endIndex > boundaryIndex else { return nil }
            }
            let end = scalarBoundaries[endIndex]
            result.append(payload.subdata(in: offset..<end))
            boundaryIndex = endIndex
        }
        return result
    }
}

/// CoreBluetooth may restore an old auto-reconnect request as `.connecting`
/// without ever delivering a new connect/fail callback to the relaunched app.
/// Keep the decision independent from CoreBluetooth so every restored state is
/// explicit and covered by a host test.
enum BLERelayRecoveredPeripheralState {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

enum BLERelayRecoveredPeripheralAction: Equatable {
    case authenticate
    case restartPendingConnection
    case connect
    case discard
}

enum BLERelayReconnectPolicy {
    /// Give a fresh system-owned AutoReconnect attempt time to finish before
    /// replacing it. A restored pending attempt has no trustworthy start time,
    /// so it is restarted immediately instead.
    static let freshSystemAttemptGrace: TimeInterval = 12
    /// A physical Passport-side disconnect is a temporary selection decision.
    /// Retrying immediately steals the single BLE slot back; stopping forever
    /// prevents a later Passport-side selection from taking effect.
    static let manualDisconnectRetryFloor: TimeInterval = 15

    static func temporaryBackoff(reason: String, retryAfter: Int,
                                 handoffRemaining: Int,
                                 pairingRemaining: Int) -> TimeInterval? {
        switch reason {
        case "handoff":
            return TimeInterval(max(max(handoffRemaining, retryAfter), 10))
        case "yield":
            return TimeInterval(max(retryAfter, 10))
        case "manual_disconnect":
            return max(TimeInterval(retryAfter), manualDisconnectRetryFloor)
        case "handoff_target_mismatch", "enrollment_reserved",
             "ota_owned_by_another_companion":
            return TimeInterval(max(max(max(handoffRemaining, pairingRemaining),
                                        retryAfter), 10))
        case "legacy_client", "legacy_client_backoff", "hello_timeout":
            return TimeInterval(max(retryAfter, 15))
        default:
            return nil
        }
    }

    static func recoveredAction(state: BLERelayRecoveredPeripheralState,
                                wasAuthorized: Bool) -> BLERelayRecoveredPeripheralAction {
        switch state {
        case .connected:
            // Authentication is still mandatory. A restored transport link is
            // never proof that the companion is trusted.
            return .authenticate
        case .connecting, .disconnecting:
            return wasAuthorized ? .restartPendingConnection : .discard
        case .disconnected:
            return wasAuthorized ? .connect : .discard
        }
    }

    static func mayRetry(wasAuthorized: Bool, denied: Bool,
                         userDisconnected: Bool, backoffRemaining: TimeInterval) -> Bool {
        wasAuthorized && !denied && !userDisconnected && backoffRemaining <= 0
    }
}
