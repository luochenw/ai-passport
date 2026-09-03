import Foundation

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - Headless delivery: `codex exec resume <thread> "<text>"` (no window, no UI)

/// Delivers a voice-recognized message into an existing Codex thread by shelling out to
/// the `codex` CLI's own non-interactive resume command, instead of driving Codex
/// Desktop's UI (an earlier Accessibility-based approach -- window activation, a
/// codex://threads/{id} deep link to switch conversations, then simulated keystrokes --
/// worked, but Codex's own open-url handler always pulled its window to the foreground
/// no matter what, which the user did not want for a casual voice aside).
///
/// Trade-off, confirmed with the user before switching to this: `codex exec resume`
/// runs as a completely separate OS process that appends the new turn straight to the
/// same rollout file on disk -- the device (which just tails that file) picks it up
/// immediately, but Codex Desktop's already-open window is a *different* process with
/// its own in-memory thread state, so it will not visibly update until that thread is
/// closed and reopened there. If Desktop's own process happens to be mid-turn on this
/// exact thread when this runs, `~/.codex/thread-writer-locks/<id>.lock` (a real flock
/// found in codex-rs's actual source) makes the two writers conflict safely -- this
/// invocation fails cleanly with a non-zero exit rather than corrupting the rollout.
enum HeadlessCodexSender {

    /// Mirrors codex-rs's own `codex_app_search_dirs`/`find_existing_codex_app_path`
    /// (cli/src/desktop_app/mac.rs) so this looks in the same places the `codex` CLI
    /// itself would to find the Desktop app bundle, then reaches into it for the
    /// bundled `codex` executable -- the same binary already used throughout this
    /// session's manual testing (`/Applications/ChatGPT.app/Contents/Resources/codex`).
    private static func findCodexBinary() -> String? {
        var searchDirs = ["/Applications"]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            searchDirs.append("\(home)/Applications")
        }
        for dir in searchDirs {
            for appName in ["ChatGPT.app", "Codex.app"] {
                let candidate = "\(dir)/\(appName)/Contents/Resources/codex"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Boils a raw stderr tail down to a short, human-readable reason that fits the
    /// device's small status display -- the raw text is Rust panic/log noise (hook
    /// lines, backtraces, request ids) that's meaningless on a 216px-wide screen.
    /// Falls back to the exit code alone when the text doesn't match a known case.
    private static func classifyFailure(exitCode: Int32, stderr: String) -> String {
        if stderr.contains("already has an active writer") {
            return "会话正被其它地方占用,请切换/关闭后重试"
        }
        if stderr.contains("409 Conflict") {
            return "模型服务暂不可用(渠道被禁用),请检查本地代理"
        }
        if stderr.contains("Not inside a trusted directory") {
            return "工作目录不受信任(内部配置问题)"
        }
        return "发送失败(退出码 \(exitCode))"
    }

    /// Fire-and-forget: starts `codex exec resume` and returns immediately (a real turn
    /// can take anywhere from a few seconds to a couple of minutes; nothing else in this
    /// process should block waiting on it). Logs both the outcome and the tail of
    /// stdout/stderr when it finishes, from the process's own termination handler.
    ///
    /// Forces `--sandbox read-only` rather than inheriting whatever sandbox policy the
    /// user's interactive config.toml specifies: this runs unattended with no human able
    /// to answer an approval prompt, so any action needing elevated permissions should
    /// just fail back to the model as an error instead of hanging. Deliberately does
    /// *not* use `--dangerously-bypass-approvals-and-sandbox` -- that skips sandboxing
    /// entirely, which is a real safety regression for a channel triggered by (possibly
    /// misheard) voice input. `--skip-git-repo-check` is required because the relay's own
    /// working directory isn't inside a git repo Codex trusts.
    ///
    /// `model`, when known, is passed as `--model` so the resumed turn continues with
    /// whatever model the session's own most recent turn actually used (a session can
    /// switch models mid-conversation) instead of silently falling back to whatever this
    /// Mac's config.toml happens to default to -- `codex exec resume` does exactly that
    /// fallback, with only a warning on stderr, when no `--model` is given and the
    /// session's recorded model differs from the config default.
    static func send(threadId: String?, model: String?, text: String, onFailure: ((String) -> Void)? = nil) {
        guard let codexPath = findCodexBinary() else {
            log("[voice->codex] 找不到 codex 可执行文件(ChatGPT.app/Codex.app 均未找到),放弃发送")
            onFailure?("找不到 codex 可执行文件")
            return
        }

        var args = ["exec", "--sandbox", "read-only", "--skip-git-repo-check"]
        if let model = model {
            args.append(contentsOf: ["--model", model])
        }
        args.append("resume")
        if let threadId = threadId {
            args.append(threadId)
        } else {
            args.append("--last")
        }
        args.append(text)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        process.terminationHandler = { proc in
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
            let out = outData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let err = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if proc.terminationStatus == 0 {
                log("[voice->codex] codex exec resume 完成(退出码 0),消息已写入会话文件"
                    + (out.isEmpty ? "" : " -- 输出末尾: \(out.suffix(300))"))
            } else {
                log("[voice->codex] codex exec resume 失败(退出码 \(proc.terminationStatus))"
                    + (err.isEmpty ? "" : ": \(err.suffix(500))"))
                onFailure?(classifyFailure(exitCode: proc.terminationStatus, stderr: err))
            }
        }

        do {
            try process.run()
            log("[voice->codex] 已启动 codex exec resume (thread=\(threadId ?? "--last"), model=\(model ?? "配置默认")),后台无头运行中,不会弹出任何窗口")
        } catch {
            log("[voice->codex] 启动 codex exec resume 失败: \(error)")
            onFailure?("启动失败: \(error.localizedDescription)")
        }
    }
}

