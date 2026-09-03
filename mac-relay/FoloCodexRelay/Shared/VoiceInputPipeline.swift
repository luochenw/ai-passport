import Foundation
import Speech
import AVFoundation

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - Voice input pipeline: AUDIO fragments -> ADPCM decode -> Speech -> Codex

/// Reassembles AUDIO-characteristic notify fragments into one complete ADPCM byte
/// stream per "long-press DOWN to talk" utterance (START...END, matching the DATA
/// characteristic's own START/END flag convention), decodes it to 16kHz/16-bit PCM,
/// runs Chinese speech recognition, and -- if that produced non-empty final text --
/// injects it into Codex's composer and sends it. Confined to its own serial queue
/// (mirrors BLERelay/CodexBrowserModel's single-queue-confinement pattern), reached only
/// via handleChunk, which BLERelay.onAudioChunk calls directly on bleQueue and which
/// hands off to `queue` immediately, exactly like onCmdRequest -> CodexBrowserModel.
final class VoiceInputPipeline {
    private let queue = DispatchQueue(label: "com.folotoy.codexrelay.voice")
    private var buffer = Data()
    private var isCollecting = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    /// Set by the entry point to CodexBrowserModel.currentSessionContext. Lets a voice
    /// message land in the same session the device is currently browsing (rather than
    /// whatever conversation Codex's real window happened to already have open -- those
    /// are two independent things unless this is wired up) and continue with that
    /// session's own current model rather than silently falling back to this Mac's
    /// config.toml default. Calls back on whatever queue CodexBrowserModel's modelQueue
    /// uses.
    var sessionContextProvider: ((@escaping (_ threadId: String?, _ model: String?) -> Void) -> Void)?

    /// Set by the entry point to CodexBrowserModel.reportVoiceError. Lets a failed
    /// `codex exec resume` (write-lock conflict, the user's model relay rejecting the
    /// request, etc.) show up on the device screen instead of only ever being visible in
    /// this Mac process's own log file.
    var onSendFailure: ((String) -> Void)?

    /// 转写出来的文字往哪儿送。由各端入口注入 —— macOS 上注入
    /// HeadlessCodexSender(起子进程跑 `codex exec`),iOS 上没有这个能力,
    /// 注入一个把文字回显到设备屏幕的实现,或者干脆不注入。
    ///
    /// ⚠ 这里必须是注入而不是直接调 HeadlessCodexSender:那个类要 fork/exec,
    /// 而 iOS 内核层面禁止 fork/exec,直接调会让整个 Shared/ 编不过 iOS ——
    /// 这曾经是 Shared/ 里唯一一处真正的编译障碍。识别、ADPCM 解码、分片
    /// 重组全都是三端通用的,不该被最后一步的"送到哪儿"拖下水。
    var onTranscript: ((_ text: String, _ threadId: String?, _ model: String?) -> Void)?

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            log("语音识别权限状态 (SFSpeechRecognizer.requestAuthorization) = \(status.rawValue) (3=authorized)")
        }
    }

    /// Entry point for BLERelay.onAudioChunk (called on bleQueue). Hands off to `queue`
    /// immediately so bleQueue is never blocked by ADPCM decode / Speech / Accessibility
    /// work.
    func handleChunk(flags: UInt8, payload: Data) {
        queue.async { [weak self] in
            self?.processChunk(flags: flags, payload: payload)
        }
    }

    private func processChunk(flags: UInt8, payload: Data) {
        if flags & RelayFlags.start != 0 {
            if isCollecting {
                log("[voice] 收到新的 START,但上一段语音还没收到 END -- 丢弃上一段未完成的数据")
            }
            buffer = Data()
            isCollecting = true
            log("[voice] 开始接收一段语音")
        }
        guard isCollecting else {
            log("[voice] 收到语音分片但当前没有进行中的录音(缺少 START),忽略")
            return
        }
        if !payload.isEmpty {
            buffer.append(payload)
        }
        if flags & RelayFlags.end != 0 {
            let collected = buffer
            buffer = Data()
            isCollecting = false
            log("[voice] 收到 END,本段语音共 \(collected.count) 字节 ADPCM 数据")
            finalizeUtterance(adpcm: collected)
        }
    }

    private func finalizeUtterance(adpcm: Data) {
        guard !adpcm.isEmpty else {
            log("[voice] 本段语音没有任何音频数据,放弃")
            return
        }
        let pcm = IMAADPCM.decode(adpcm)
        guard !pcm.isEmpty else {
            log("[voice] ADPCM 解码结果为空,放弃")
            return
        }
        log("[voice] ADPCM 解码得到 \(pcm.count) 个 PCM 采样 (约 \(String(format: "%.2f", Double(pcm.count) / 16000.0)) 秒)")
        recognizeSpeech(pcm: pcm)
    }

    private func recognizeSpeech(pcm: [Int16]) {
        guard let recognizer = recognizer else {
            log("[voice] zh-CN 语音识别器不可用,放弃")
            return
        }
        guard let audioBuffer = Self.makeBuffer(pcm: pcm) else {
            log("[voice] 构造 AVAudioPCMBuffer 失败,放弃")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        // The full utterance is already fully decoded in memory -- feed it once and
        // call endAudio() immediately rather than streaming, per spec.
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            // Documented fallback, not a new risk introduced here: when on-device
            // recognition isn't available on this Mac/macOS version, Speech falls back
            // to Apple's server-side recognizer, same as it would for any other app.
            log("[voice] 本机 (on-device) 识别在这台机器上不可用,将退回服务器识别")
        }
        request.append(audioBuffer)
        request.endAudio()
        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                log("[voice] 语音识别出错: \(error)")
                return
            }
            guard let result = result, result.isFinal else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                log("[voice] 识别结果为空,不发送进 Codex")
                return
            }
            guard let deliver = self.onTranscript else {
                // 没人接就说清楚。静默丢掉的话,用户看到的是"按住说话没反应",
                // 而日志里连识别成功都看得见 —— 最难查的那种。
                log("[voice] 识别出「\(text)」,但本端没有接收方(这个平台不能跑 Codex),丢弃")
                self.onSendFailure?("这台设备不能运行 Codex,语音没有送出")
                return
            }
            log("[voice] 识别结果: \"\(text)\" -- 发送进 Codex")
            if let provider = self.sessionContextProvider {
                provider { threadId, model in
                    deliver(text, threadId, model)
                }
            } else {
                deliver(text, nil, nil)
            }
        }
    }

    private static func makeBuffer(pcm: [Int16]) -> AVAudioPCMBuffer? {
        guard !pcm.isEmpty else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            return nil
        }
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)) else {
            return nil
        }
        audioBuffer.frameLength = AVAudioFrameCount(pcm.count)
        guard let channel = audioBuffer.int16ChannelData else { return nil }
        pcm.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: pcm.count)
        }
        return audioBuffer
    }
}

