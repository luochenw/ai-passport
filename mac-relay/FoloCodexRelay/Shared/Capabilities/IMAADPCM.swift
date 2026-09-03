import Foundation

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - IMA ADPCM decoder (voice input)
//
// The device encodes each 512-sample recording batch with standard IMA ADPCM (4
// bit/sample, 4:1 compression) before notifying it over the AUDIO characteristic; the
// Mac side only ever needs to decode. This is the textbook step/index-table algorithm
// (same tables and update rules as the firmware's C encoder), verified byte-compatible
// against a from-scratch Swift IMA ADPCM encoder in a standalone round-trip harness
// (encode -> decode -> compare) before being wired into the live BLE path -- see the
// task report for that test's output.
enum IMAADPCM {
    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    static let indexTable: [Int32] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    /// predictor/stepIndex for one in-progress decode. Callers must create a fresh
    /// State() per utterance -- never reuse state across two separate recordings.
    struct State {
        var predictor: Int32 = 0
        var stepIndex: Int32 = 0
    }

    private static func decodeCode(_ code: UInt8, _ state: inout State) -> Int16 {
        let step = stepTable[Int(state.stepIndex)]
        var diff = step >> 3
        let c = Int32(code)
        if c & 4 != 0 { diff += step }
        if c & 2 != 0 { diff += step >> 1 }
        if c & 1 != 0 { diff += step >> 2 }
        if c & 8 != 0 { state.predictor -= diff } else { state.predictor += diff }
        state.predictor = max(-32768, min(32767, state.predictor))
        state.stepIndex += indexTable[Int(c)]
        state.stepIndex = max(0, min(88, state.stepIndex))
        return Int16(state.predictor)
    }

    /// Decodes a full ADPCM byte stream (one byte = 2 packed 4-bit codes, low nibble =
    /// earlier sample) into 16-bit PCM samples. predictor/stepIndex start from 0/0, per
    /// the "never carried across utterances" rule above.
    static func decode(_ bytes: Data) -> [Int16] {
        var state = State()
        var out: [Int16] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(decodeCode(b & 0x0F, &state))
            out.append(decodeCode((b >> 4) & 0x0F, &state))
        }
        return out
    }
}

