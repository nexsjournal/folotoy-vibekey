import Foundation
import zlib

/// gzip 压缩 / 解压(火山引擎协议要求)。使用系统 zlib,windowBits = 31 表示 gzip 格式。
nonisolated enum Gzip {
    enum Failure: Error { case zlib(Int32), tooLarge }

    /// 解压结果上限,防止异常数据占满内存。
    static let maxOutput = 4 * 1_048_576

    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.zlib(status) }
        defer { deflateEnd(&stream) }
        return try run(&stream, input: data, decompress: false)
    }

    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let status = inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.zlib(status) }
        defer { inflateEnd(&stream) }
        return try run(&stream, input: data, decompress: true)
    }

    private static func run(_ stream: inout z_stream, input: Data, decompress: Bool) throws -> Data {
        var output = Data()
        var input = input  // 需要可变指针
        try input.withUnsafeMutableBytes { (source: UnsafeMutableRawBufferPointer) in
            stream.next_in = source.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(source.count)
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var status: Int32 = Z_OK
            repeat {
                let produced: Int = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    status = decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                    return destination.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END || (status == Z_BUF_ERROR && produced > 0) else {
                    throw Failure.zlib(status)
                }
                output.append(contentsOf: buffer.prefix(produced))
                if output.count > maxOutput { throw Failure.tooLarge }
                if decompress, status == Z_OK, stream.avail_in == 0, produced == 0 { break }
            } while status != Z_STREAM_END
        }
        return output
    }
}
