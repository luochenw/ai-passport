import Foundation

@main
struct TestWalkieProtocol {
    static func main() {
        var frame = Data(repeating: 0, count: WalkieWire.headerSize + 80)
        frame[0] = WalkieWire.protocolVersion
        frame[1] = WalkieWire.flagStart
        frame[2] = 0x34
        frame[3] = 0x12
        frame[6] = 160

        precondition(WalkieWire.validate(frame))
        precondition(WalkieWire.streamID(in: frame) == 0x1234)
        precondition(WalkieWire.hasStart(frame))
        precondition(!WalkieWire.hasEnd(frame))

        frame[1] = WalkieWire.flagEnd
        precondition(WalkieWire.hasEnd(frame))

        var queue = WalkieRealtimeQueue(limit: 3)
        frame[1] = WalkieWire.flagStart
        queue.enqueue(frame)
        frame[1] = 0
        for sequence in 1...4 {
            frame[4] = UInt8(sequence)
            queue.enqueue(frame)
        }
        frame[1] = WalkieWire.flagEnd
        queue.enqueue(frame)
        precondition(queue.frames.count == 3)
        precondition(queue.frames.first?[1] == WalkieWire.flagStart)
        precondition(queue.frames.last?[1] == WalkieWire.flagEnd)

        frame[1] = WalkieWire.flagStart
        frame[2] = 0x78
        frame[3] = 0x56
        queue.enqueue(frame)
        precondition(queue.frames.count == 1)
        precondition(WalkieWire.streamID(in: queue.frames[0]) == 0x5678)

        frame.removeLast()
        precondition(!WalkieWire.validate(frame))
        print("walkie Swift protocol: PASS")
    }
}
