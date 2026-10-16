import Foundation

/// Passport 麦克风上行的 IMA ADPCM 解码(docs/protocol.md 帧类型 0x02)。
///
/// 每块 164 字节 = 4 字节头(int16 LE 预测值、uint8 步长索引、uint8 保留)+ 160 字节
/// (320 个 4 bit 样本,低半字节在前)= 20 ms,16 kHz 单声道。块自包含,块之间不传递状态。
nonisolated enum IMAADPCMDecoder {
    static let blockBytes = 164
    static let headerBytes = 4
    static let samplesPerBlock = 320
    static let sampleRate: Double = 16_000

    static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    /// 解码一个 nibble,更新预测值与步长索引。
    @inline(__always)
    static func decodeNibble(_ nibble: UInt8, predictor: inout Int32, index: inout Int) -> Int16 {
        let code = Int(nibble & 0x0F)
        let step = stepTable[index]
        var diff = step >> 3
        if code & 4 != 0 { diff += step }
        if code & 2 != 0 { diff += step >> 1 }
        if code & 1 != 0 { diff += step >> 2 }
        predictor += (code & 8 != 0) ? -diff : diff
        predictor = min(max(predictor, -32768), 32767)
        index = min(max(index + indexTable[code], 0), 88)
        return Int16(predictor)
    }

    /// 解码一块为 320 个 Int16 样本;长度不足一块时返回空数组,多余字节忽略。
    static func decodeBlockPCM(_ block: UnsafeRawBufferPointer) -> [Int16] {
        guard block.count >= blockBytes else { return [] }
        var predictor = Int32(Int16(bitPattern: UInt16(block[0]) | (UInt16(block[1]) << 8)))
        var index = min(Int(block[2]), 88)
        var pcm = [Int16](repeating: 0, count: samplesPerBlock)
        for i in 0..<(samplesPerBlock / 2) {
            let byte = block[headerBytes + i]
            pcm[2 * i] = decodeNibble(byte & 0x0F, predictor: &predictor, index: &index)
            pcm[2 * i + 1] = decodeNibble(byte >> 4, predictor: &predictor, index: &index)
        }
        return pcm
    }

    /// 解码一块为 [-1, 1) 的 Float 样本(16 kHz 单声道)。
    static func decodeBlock(_ block: [UInt8]) -> [Float] {
        block.withUnsafeBytes { raw in
            decodeBlockPCM(raw).map { Float($0) / 32768 }
        }
    }

    /// 解码一帧负载里连续的整块(USB 每帧 2 块,BLE 每帧 1 块);末尾不足一块的字节忽略。
    static func decode(_ payload: Data) -> [Float] {
        let blocks = payload.count / blockBytes
        guard blocks > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(blocks * samplesPerBlock)
        payload.withUnsafeBytes { raw in
            for b in 0..<blocks {
                let slice = UnsafeRawBufferPointer(rebasing: raw[(b * blockBytes)..<((b + 1) * blockBytes)])
                for sample in decodeBlockPCM(slice) {
                    out.append(Float(sample) / 32768)
                }
            }
        }
        return out
    }
}
