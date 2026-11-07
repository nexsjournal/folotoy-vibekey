import Foundation

/// USB 串口字节流的解码泵:把串口读到的字节拆成协议消息和二进制帧。
///
/// 在串口的内部串行队列上调用(不加锁,同一实例只能在一个队列上用):
/// 音频帧直接交给 `DeviceFrameSink`(不经过主线程),协议消息返回给调用方切回主线程处理,
/// 不含 `{"t":` 的 ESP-IDF 日志行在这里就丢掉。
nonisolated final class USBStreamPump: @unchecked Sendable {
    private var decoder = StreamDecoder()
    private let frames: any DeviceFrameSink

    init(frames: any DeviceFrameSink) {
        self.frames = frames
    }

    /// 返回这段字节里解析出的协议消息(按到达顺序)。
    func feed(_ data: Data) -> [DeviceMessage] {
        var messages: [DeviceMessage] = []
        for item in decoder.feed(data) {
            switch item {
            case .line(let line):
                if let message = DeviceMessage.parse(line) {
                    messages.append(message)
                }
            case .frame(let type, let seq, let payload):
                frames.receiveFrame(type: type, seq: seq, payload: payload, from: .usb)
            }
        }
        return messages
    }
}
