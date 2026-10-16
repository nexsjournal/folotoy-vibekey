import Foundation
import os

/// 接收设备上行二进制帧的小接口。传输层(USB 解帧、BLE 通知)只依赖它,不关心帧最后怎么处理。
/// 实现必须线程安全:USB 在串口队列上调用,BLE 在主线程调用。
nonisolated protocol DeviceFrameSink: AnyObject, Sendable {
    /// 一个完整的二进制帧(帧头已去掉)。
    func receiveFrame(type: UInt8, seq: UInt8, payload: Data, from link: DeviceLinkKind)
    /// BLE Audio In 通知的原始字节;一帧可能被拆成多个通知,由实现重新拼帧。
    func receiveBLEAudio(_ data: Data)
    /// BLE 断开或重连时丢弃半帧。
    func resetBLE()
}

/// 麦克风上行:在自己的串行队列上解 IMA ADPCM,回调 16 kHz 单声道 float。
///
/// - 只接受当前连接链路(`setActive`)的帧,避免 USB / BLE 切换时两路音频叠在一起。
/// - 按帧 `seq` 统计丢帧,只记日志。
/// - `handler` / `active` 由主线程设置,用锁保护;其余状态只在 `queue` 上访问。
nonisolated final class MicStream: DeviceFrameSink, @unchecked Sendable {
    private struct Shared: Sendable {
        var handler: (@Sendable ([Float]) -> Void)?
        var active: DeviceLinkKind?
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "com.inputbetter.InputBetter.device.mic", qos: .userInteractive)
    // 以下只在 queue 上访问。
    private var bleDecoder = StreamDecoder()
    private var lastSeq: UInt8?
    private var lastLink: DeviceLinkKind?
    private var lostFrames = 0

    /// 设置样本回调;回调在 `queue` 上执行。
    func setHandler(_ handler: (@Sendable ([Float]) -> Void)?) {
        shared.withLock { $0.handler = handler }
    }

    /// 设置当前连接链路;nil 表示未连接,此时丢弃所有帧。
    func setActive(_ link: DeviceLinkKind?) {
        shared.withLock { $0.active = link }
    }

    func receiveFrame(type: UInt8, seq: UInt8, payload: Data, from link: DeviceLinkKind) {
        queue.async { [self] in
            handleFrame(type: type, seq: seq, payload: payload, from: link)
        }
    }

    func receiveBLEAudio(_ data: Data) {
        queue.async { [self] in
            for item in bleDecoder.feed(data) {
                if case .frame(let type, let seq, let payload) = item {
                    handleFrame(type: type, seq: seq, payload: payload, from: .ble)
                }
            }
        }
    }

    func resetBLE() {
        queue.async { [self] in
            bleDecoder.reset()
        }
    }

    /// 在 queue 上执行:过滤链路、统计丢帧、解码并回调。
    private func handleFrame(type: UInt8, seq: UInt8, payload: Data, from link: DeviceLinkKind) {
        guard type == DeviceFrame.typeADPCM else { return }
        let (handler, active) = shared.withLock { ($0.handler, $0.active) }
        guard active == link else { return }

        if link != lastLink {
            lastLink = link
            lastSeq = nil
        }
        if let lastSeq {
            // seq 是 0...255 循环计数,用回绕减法求间隔。
            let gap = Int(seq &- lastSeq) - 1
            if gap > 0 {
                lostFrames += gap
                DeviceLog.link.debug("mic: lost \(gap) frame(s) via \(link.rawValue, privacy: .public), total \(self.lostFrames)")
            }
        }
        lastSeq = seq

        guard let handler else { return }
        let samples = IMAADPCMDecoder.decode(payload)
        if !samples.isEmpty {
            handler(samples)
        }
    }
}
