import Darwin
import Foundation

/// `/dev/cu.*` 串口的最小封装:115200 raw、TIOCEXCL 独占、关 HUPCL,打开后先清 RTS 再清 DTR。
///
/// fd 只在内部串行队列上读写;`onData`/`onClose` 也在该队列上调用,由调用方自行切线程。
nonisolated final class SerialPort: @unchecked Sendable {
    enum Failure: LocalizedError {
        case open(path: String, code: Int32)
        case configure(code: Int32)

        var errorDescription: String? {
            switch self {
            case .open(let path, let code) where code == EBUSY:
                String(localized: "\(path) 正被其它程序占用（例如 idf.py monitor）", bundle: .l10n)
            case .open(let path, let code):
                String(localized: "无法打开 \(path)：\(String(cString: strerror(code)))", bundle: .l10n)
            case .configure(let code):
                String(localized: "串口配置失败：\(String(cString: strerror(code)))", bundle: .l10n)
            }
        }
    }

    let path: String

    private let fd: Int32
    private let queue: DispatchQueue
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable (Int32?) -> Void
    // 以下状态只在 queue 上访问。
    private var readSource: DispatchSourceRead?
    private var isClosed = false
    private var readBuffer = [UInt8](repeating: 0, count: 2048)

    /// - Parameters:
    ///   - onData: 收到数据,在内部串行队列上调用。
    ///   - onClose: 端口关闭,参数为导致关闭的 errno;主动 `close()` 时为 nil。在内部队列上调用。
    init(
        path: String,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (Int32?) -> Void
    ) throws {
        self.path = path
        self.onData = onData
        self.onClose = onClose
        self.queue = DispatchQueue(label: "com.inputbetter.InputBetter.serial", qos: .userInitiated)

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw Failure.open(path: path, code: errno)
        }
        do {
            try Self.configure(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        // resume 之前没有并发访问。
        readSource = source
        source.resume()
    }

    /// 异步写入。设备接收缓冲满(EAGAIN)时短暂重试,仍写不进去就丢掉这次写入,不关闭端口;
    /// 设备卡死由上层的心跳超时处理。
    func write(_ data: Data) {
        queue.async { [self] in
            writeNow(data)
        }
    }

    /// 同步写入最后一条数据并关闭端口(退出前发 `bye` 用,保证写出后才返回)。
    func writeAndClose(_ data: Data) {
        queue.sync {
            writeNow(data)
            finish(nil)
        }
    }

    func close() {
        queue.async { [self] in
            finish(nil)
        }
    }

    private func writeNow(_ data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            var retries = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if code == EAGAIN || code == EINTR {
                    if retries < 50 {
                        retries += 1
                        usleep(2_000)
                        continue
                    }
                    DeviceLog.link.notice("serial write dropped (\(raw.count - offset) bytes): device not reading")
                    return
                }
                finish(code)
                return
            }
        }
    }

    private func readAvailable() {
        while !isClosed {
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                onData(Data(readBuffer[0..<count]))
                if count < readBuffer.count {
                    return
                }
            } else if count == 0 {
                // 非阻塞 tty 读到 0 表示对端挂断:设备被拔出或复位后重新枚举。
                finish(ENXIO)
                return
            } else {
                let code = errno
                if code != EAGAIN, code != EINTR {
                    finish(code)
                }
                return
            }
        }
    }

    private func finish(_ code: Int32?) {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onClose(code)
    }

    private static func configure(_ fd: Int32) throws {
        // 独占打开,避免 idf.py monitor 等程序同时读取,抢走协议数据。
        guard ioctl(fd, IOCTL.exclusive) != -1 else {
            throw Failure.configure(code: errno)
        }

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            throw Failure.configure(code: errno)
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // 关闭 HUPCL:否则 close 时系统会拉低 DTR/RTS,顺序不确定时可能复位芯片。
        options.c_cflag &= ~tcflag_t(HUPCL)
        cfsetspeed(&options, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw Failure.configure(code: errno)
        }

        // ESP32-C3 USB Serial/JTAG 把 DTR/RTS 当作复位 / 下载模式控制:DTR=0 且 RTS=1 会复位芯片。
        // macOS 打开端口时两者都置 1;先清 RTS 再清 DTR,途经 (DTR=1,RTS=0) 而不是 (0,1),不会复位设备。
        var rts = TIOCM_RTS
        _ = ioctl(fd, IOCTL.clearModemBits, &rts)
        var dtr = TIOCM_DTR
        _ = ioctl(fd, IOCTL.clearModemBits, &dtr)
    }

    /// <sys/ttycom.h> 的 _IO/_IOW 宏无法导入 Swift,数值按 ioccom.h 展开。
    private enum IOCTL {
        static let exclusive: UInt = 0x2000_740D  // TIOCEXCL = _IO('t', 13)
        static let clearModemBits: UInt = 0x8004_746B  // TIOCMBIC = _IOW('t', 107, int)
    }
}
