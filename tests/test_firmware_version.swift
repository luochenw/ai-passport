import Foundation

@main
struct TestFirmwareVersion {
    private static func expect(_ actual: FirmwareInstallDisposition,
                               _ expected: FirmwareInstallDisposition,
                               _ label: String) {
        guard actual == expected else {
            fputs("FAIL \(label): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(.classify(device: "0.1.0", bundled: "0.2.0"), .upgrade, "minor upgrade")
        expect(.classify(device: "1.0.0", bundled: "0.9.9"), .downgrade, "major downgrade")
        expect(.classify(device: "0.1.0", bundled: "0.1.0"), .reinstall, "same release")
        expect(.classify(device: "0.1.0-dev+g1111111", bundled: "0.1.0-dev+g2222222"),
               .reinstall, "different build metadata")
        expect(.classify(device: "0.1.0-dev+g1111111", bundled: "0.1.0"),
               .upgrade, "release outranks prerelease")
        expect(.classify(device: nil, bundled: "0.1.0"), .unknown, "old firmware")
        expect(.classify(device: "legacy", bundled: "0.1.0"), .unknown, "invalid current version")

        print("firmware version tests: PASS")
    }
}
