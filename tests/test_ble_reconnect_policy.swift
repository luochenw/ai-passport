import Foundation

@main
struct TestBLERelayReconnectPolicy {
    private static func expect(_ actual: BLERelayRecoveredPeripheralAction,
                               _ expected: BLERelayRecoveredPeripheralAction,
                               _ label: String) {
        guard actual == expected else {
            fputs("FAIL \(label): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let suiteName = "test.companion-name." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        precondition(CompanionNamePolicy.load(defaults: defaults) ==
                     CompanionNamePolicy.platformDefault)
        precondition(CompanionNamePolicy.sanitized("我的\nMac\0") == "我的Mac")
        precondition(CompanionNamePolicy.validationMessage(for: "") != nil)
        precondition(CompanionNamePolicy.validationMessage(
            for: String(repeating: "名", count: 17)) != nil)
        precondition(CompanionNamePolicy.save("工作 Mac", defaults: defaults))
        precondition(CompanionNamePolicy.load(defaults: defaults) == "工作 Mac")
        precondition(CompanionAuthCommandWire.payload(operation: 0x08,
                                                      value: "工作 Mac") ==
                     Data([0x08]) + Data("工作 Mac".utf8))
        precondition(CompanionAuthCommandWire.payload(
            operation: 0x08, value: String(repeating: "名", count: 17)) == nil)
        precondition(CompanionAuthCommandWire.payload(operation: 0x08,
                                                      value: "bad\nname") == nil)
        precondition(CompanionAuthStateLine.parse("current.name=%E6%88%91%3DMac") ==
                     CompanionAuthStateLine(key: "current.name",
                                            rawValue: "%E6%88%91%3DMac",
                                            value: "我=Mac"))
        precondition(CompanionAuthStateLine.parse("reason=handoff=extra")?.value ==
                     "handoff=extra")
        precondition(CompanionAuthStateLine.parse("missing-separator") == nil)

        let boundaryText = String(repeating: "a", count: 499) + "\n尾\n"
        let boundaryChunks = RemoteScreenChunker.chunks(boundaryText,
                                                        chunkLimit: 500)!
        precondition(boundaryChunks.count == 2)
        precondition(boundaryChunks[0].count == 499 &&
                     boundaryChunks[0].last != 0x0A)
        precondition(boundaryChunks[1].first == 0x0A &&
                     boundaryChunks[1].last == 0x0A)
        precondition(Data(boundaryChunks.joined()) == Data(boundaryText.utf8))
        precondition(boundaryChunks.allSatisfy { String(data: $0, encoding: .utf8) != nil })

        let unicodeText = "甲乙丙丁\n下一页\n"
        let unicodeChunks = RemoteScreenChunker.chunks(unicodeText, chunkLimit: 8)!
        precondition(unicodeChunks.dropLast().allSatisfy { $0.last != 0x0A })
        precondition(unicodeChunks.allSatisfy { String(data: $0, encoding: .utf8) != nil })
        precondition(Data(unicodeChunks.joined()) == Data(unicodeText.utf8))

        expect(BLERelayReconnectPolicy.recoveredAction(state: .connected,
                                                       wasAuthorized: true),
               .authenticate, "connected links reauthenticate")
        expect(BLERelayReconnectPolicy.recoveredAction(state: .connecting,
                                                       wasAuthorized: true),
               .restartPendingConnection, "stale pending connection is restarted")
        expect(BLERelayReconnectPolicy.recoveredAction(state: .disconnecting,
                                                       wasAuthorized: true),
               .restartPendingConnection, "stale disconnect is restarted")
        expect(BLERelayReconnectPolicy.recoveredAction(state: .disconnected,
                                                       wasAuthorized: true),
               .connect, "remembered disconnected device reconnects")
        expect(BLERelayReconnectPolicy.recoveredAction(state: .connecting,
                                                       wasAuthorized: false),
               .discard, "untrusted pending connection is discarded")

        precondition(BLERelayReconnectPolicy.mayRetry(
            wasAuthorized: true, denied: false, userDisconnected: false,
            backoffRemaining: 0))
        precondition(!BLERelayReconnectPolicy.mayRetry(
            wasAuthorized: true, denied: true, userDisconnected: false,
            backoffRemaining: 0))
        precondition(!BLERelayReconnectPolicy.mayRetry(
            wasAuthorized: true, denied: false, userDisconnected: true,
            backoffRemaining: 0))
        precondition(!BLERelayReconnectPolicy.mayRetry(
            wasAuthorized: true, denied: false, userDisconnected: false,
            backoffRemaining: 1))
        precondition(BLERelayReconnectPolicy.manualDisconnectRetryFloor >= 10)
        precondition(BLERelayReconnectPolicy.temporaryBackoff(
            reason: "handoff", retryAfter: 20,
            handoffRemaining: 60, pairingRemaining: 0) == 60)
        precondition(BLERelayReconnectPolicy.temporaryBackoff(
            reason: "handoff", retryAfter: 20,
            handoffRemaining: 4, pairingRemaining: 0) == 20)
        precondition(BLERelayReconnectPolicy.temporaryBackoff(
            reason: "manual_disconnect", retryAfter: 5,
            handoffRemaining: 0, pairingRemaining: 0) ==
                     BLERelayReconnectPolicy.manualDisconnectRetryFloor)

        print("BLE reconnect policy tests: PASS")
    }
}
