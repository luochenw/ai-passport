import Foundation

/// SemVer precedence used only to explain whether the bundled image is newer
/// than the connected device. Build metadata is deliberately ignored for
/// precedence, while exact-string equality is still used to identify a true
/// same-build reinstall.
struct FirmwareSemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ raw: String) {
        let withoutBuild = raw.split(separator: "+", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0]
        let releaseAndPre = withoutBuild.split(separator: "-", maxSplits: 1,
                                               omittingEmptySubsequences: false)
        let numbers = releaseAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]),
              let patch = Int(numbers[2]) else { return nil }

        let prerelease = releaseAndPre.count == 2
            ? releaseAndPre[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty // a release outranks its prerelease
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum FirmwareInstallDisposition: Equatable {
    case upgrade
    case reinstall
    case downgrade
    case unknown

    static func classify(device: String?, bundled: String) -> Self {
        guard let device, !device.isEmpty,
              let current = FirmwareSemanticVersion(device),
              let candidate = FirmwareSemanticVersion(bundled) else { return .unknown }
        if device == bundled || current == candidate { return .reinstall }
        return candidate > current ? .upgrade : .downgrade
    }
}
