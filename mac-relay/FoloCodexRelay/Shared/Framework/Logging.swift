import Foundation
import os

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - Logging

/// Originally reused the exact FileHandle-append pattern from FoloBLETest/main.swift
/// (open/seek/write/close every single call), wrapped with a lock since this app logs
/// concurrently from multiple background queues. That per-call open/close is a full
/// syscall round trip and was fine for occasional messages, but a firmware install logs
/// (or used to -- see pumpAppStore()) thousands of lines in a tight loop, at which point
/// that file-open overhead becomes a real, measurable per-chunk bottleneck with nothing
/// to do with the actual BLE transfer speed. Keeps one FileHandle open for the process's
/// lifetime instead -- opened lazily on first use, appended to directly from then on.
final class Logger {
    static let shared = Logger()
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var resolvedPath: String?
    private var triedToOpen = false
    /// 文件写不成时的兜底。iOS 上不接 Xcode 也能从 Console.app 看到,而
    /// print 到 stdout 在那边等于扔掉。
    private let osLog = os.Logger(subsystem: "com.folotoy.codexrelay", category: "relay")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 日志文件放哪儿:能写 /tmp 就写 /tmp,写不了就退到自己的容器。
    ///
    /// 不用 `#if os(macOS)` 判断,用"能不能写"判断 —— 表达的是能力而不是
    /// 平台。macOS 上行为一字不变(`tail -f /tmp/folo_codex_relay.log` 照旧,
    /// build-an-app 那篇文档里的调试流程也照旧);iOS 沙盒里 /tmp 存在但不
    /// 可写,于是自动落到容器里。将来给 macOS 版本开沙盒时,同一段代码也
    /// 会自动做对的事。
    private static func candidatePaths() -> [String] {
        var paths = ["/tmp/folo_codex_relay.log"]
        if let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true) {
            let container = dir.appendingPathComponent("FoloCodexRelay", isDirectory: true)
            try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            paths.append(container.appendingPathComponent("relay.log").path)
        }
        return paths
    }

    private func openHandleIfNeeded() -> FileHandle? {
        if let fileHandle = fileHandle { return fileHandle }
        // 只试一轮。试不出来就一直走 os.Logger,不要每条日志都去敲一遍文件系统。
        if triedToOpen { return nil }
        triedToOpen = true
        for path in Self.candidatePaths() {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else { continue }
            }
            guard let fh = FileHandle(forWritingAtPath: path) else { continue }
            fh.seekToEndOfFile()
            fileHandle = fh
            resolvedPath = path
            return fh
        }
        osLog.error("日志文件一个都打不开,后续日志只进 os.Logger")
        return nil
    }

    func log(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamped = "[\(dateFormatter.string(from: Date()))] \(s)"
        print(stamped)
        fflush(stdout)
        guard let data = (stamped + "\n").data(using: .utf8) else { return }
        if let fh = openHandleIfNeeded() {
            fh.write(data)
        } else {
            // ⚠ 这里原来是 `try? data.write(to:)`,那是**整文件覆盖**不是追加 ——
            // 每调一次 log() 就把之前写的全冲掉,只剩最后一行。macOS 上永远
            // 走不到这条分支所以一直没暴露。改走 os.Logger:既不会互相覆盖,
            // 也不会把错误吞掉。
            osLog.notice("\(s, privacy: .public)")
        }
    }

    /// 日志实际写到哪儿了。界面上可以显示出来 —— 否则 iOS 用户根本不知道
    /// 去哪儿找,而这条路径每台设备都不一样。
    var currentPath: String? {
        lock.lock()
        defer { lock.unlock() }
        _ = openHandleIfNeeded()
        return resolvedPath
    }
}

func log(_ s: String) {
    Logger.shared.log(s)
}
