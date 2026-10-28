import Foundation

/// Encodings in the v1 support matrix (plan D2 item 1).
public enum WAVSampleEncoding: String, Sendable, Equatable {
    case pcmS16 = "pcm_s16le"
    case pcmS24 = "pcm_s24le"
    case pcmS32 = "pcm_s32le"
    case float32 = "float32le"

    public var bitsPerSample: Int {
        switch self {
        case .pcmS16: return 16
        case .pcmS24: return 24
        case .pcmS32: return 32
        case .float32: return 32
        }
    }

    public var isFloat: Bool { self == .float32 }
}

/// Container facts read directly from RIFF bytes, before any decoder sees the file.
public struct WAVInfo: Sendable, Equatable {
    public let encoding: WAVSampleEncoding
    public let extensible: Bool
    public let channels: Int
    public let sampleRateHz: Int64
    public let blockAlign: Int
    public let dataOffset: UInt64
    public let dataBytes: UInt64
    public let frameCount: Int64
    public let fileBytes: UInt64
    /// Bytes after the RIFF form that the container does not claim (recorded, not rejected).
    public let trailingBytes: UInt64
}

/// Strict RIFF/WAVE structure check (plan D2 item 1).
///
/// Accepts uncompressed PCM 16/24/32-bit and IEEE float 32-bit, mono or
/// stereo, in plain or WAVE_FORMAT_EXTENSIBLE form with the standard PCM/float
/// GUIDs and `validBits == bitsPerSample`. Rejects renamed non-WAV, RF64,
/// compressed or other encodings, >2 channels, inconsistent block align or
/// byte rate, data not frame aligned, zero rate, and truncated chunks.
public enum WAVInspector {
    static let pcmTag: UInt16 = 0x0001
    static let floatTag: UInt16 = 0x0003
    static let extensibleTag: UInt16 = 0xFFFE
    static let guidTail: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]

    public static func inspect(_ url: URL) throws -> WAVInfo {
        let path = url.path
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw AudioError(.io, path, "cannot open: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let fileBytes: UInt64
        do { fileBytes = try handle.seekToEnd(); try handle.seek(toOffset: 0) } catch {
            throw AudioError(.io, path, "cannot size file: \(error.localizedDescription)")
        }

        func read(_ count: Int, at offset: UInt64) throws -> [UInt8] {
            guard offset + UInt64(count) <= fileBytes else {
                throw AudioError(.truncated, path, "need \(count) bytes at offset \(offset); file has \(fileBytes)")
            }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw AudioError(.truncated, path, "short read at offset \(offset)")
            }
            return [UInt8](data)
        }

        guard fileBytes >= 12 else {
            if fileBytes >= 4, try read(4, at: 0) == Array("RIFF".utf8) {
                throw AudioError(.truncated, path, "RIFF header is shorter than 12 bytes")
            }
            throw AudioError(.notRIFF, path, "file is too short to be RIFF/WAVE")
        }
        let header = try read(12, at: 0)
        let magic = String(decoding: header[0..<4], as: UTF8.self)
        if magic == "RF64" || magic == "BW64" {
            throw AudioError(.unsupportedContainer, path, "\(magic) containers are not supported in v1")
        }
        guard magic == "RIFF" else { throw AudioError(.notRIFF, path, "missing RIFF magic (found \(header[0..<4].map { $0 }))") }
        guard String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else {
            throw AudioError(.notWAVE, path, "RIFF form type is not WAVE")
        }
        let riffEnd = 8 + UInt64(le32(header, 4))
        guard riffEnd <= fileBytes else {
            throw AudioError(.truncated, path, "RIFF size claims \(riffEnd) bytes; file has \(fileBytes)")
        }

        var offset: UInt64 = 12
        var format: [UInt8]?
        var data: (offset: UInt64, size: UInt64)?
        while offset + 8 <= riffEnd {
            let chunkHeader = try read(8, at: offset)
            let id = String(decoding: chunkHeader[0..<4], as: UTF8.self)
            let size = UInt64(le32(chunkHeader, 4))
            let bodyStart = offset + 8
            guard bodyStart + size <= riffEnd else {
                throw AudioError(.truncated, path, "chunk '\(id)' claims \(size) bytes past the end of the RIFF form")
            }
            if id == "fmt " {
                guard format == nil else { throw AudioError(.invalidFormat, path, "duplicate fmt chunk") }
                guard size >= 16, size <= 1024 else { throw AudioError(.invalidFormat, path, "fmt chunk size \(size) is invalid") }
                format = try read(Int(size), at: bodyStart)
            } else if id == "data" {
                guard data == nil else { throw AudioError(.invalidFormat, path, "duplicate data chunk") }
                data = (bodyStart, size)
            }
            offset = bodyStart + size + (size % 2)
        }
        guard let fmt = format else { throw AudioError(.missingFormatChunk, path, "no fmt chunk") }
        guard let data else { throw AudioError(.missingDataChunk, path, "no data chunk") }

        let tag = le16(fmt, 0)
        let channels = Int(le16(fmt, 2))
        let rate = Int64(le32(fmt, 4))
        let byteRate = Int64(le32(fmt, 8))
        let blockAlign = Int(le16(fmt, 12))
        let bits = Int(le16(fmt, 14))

        var effectiveTag = tag
        let extensible = tag == extensibleTag
        if extensible {
            guard fmt.count >= 40, le16(fmt, 16) >= 22 else {
                throw AudioError(.invalidFormat, path, "WAVE_FORMAT_EXTENSIBLE fmt chunk is too short")
            }
            let validBits = Int(le16(fmt, 18))
            let guid = Array(fmt[24..<40])
            guard Array(guid[2..<16]) == guidTail, guid[1] == 0, guid[0] == 1 || guid[0] == 3 else {
                throw AudioError(.unsupportedEncoding, path, "unsupported extensible subformat GUID")
            }
            guard validBits == bits else {
                throw AudioError(.unsupportedEncoding, path, "validBitsPerSample \(validBits) != container bits \(bits)")
            }
            effectiveTag = UInt16(guid[0])
        }

        let encoding: WAVSampleEncoding
        switch (effectiveTag, bits) {
        case (pcmTag, 16): encoding = .pcmS16
        case (pcmTag, 24): encoding = .pcmS24
        case (pcmTag, 32): encoding = .pcmS32
        case (floatTag, 32): encoding = .float32
        default:
            throw AudioError(.unsupportedEncoding, path, "format tag 0x\(String(tag, radix: 16)) with \(bits) bits is outside the v1 matrix")
        }
        guard channels > 0 else { throw AudioError(.invalidFormat, path, "channel count is zero") }
        guard channels <= 2 else {
            throw AudioError(.unsupportedChannelCount, path, "\(channels) channels; v1 supports mono or stereo only")
        }
        guard rate > 0 else { throw AudioError(.invalidFormat, path, "sample rate is zero") }
        guard blockAlign == channels * bits / 8 else {
            throw AudioError(.invalidFormat, path, "block align \(blockAlign) != channels*bits/8 (\(channels * bits / 8))")
        }
        guard byteRate == rate * Int64(blockAlign) else {
            throw AudioError(.invalidFormat, path, "byte rate \(byteRate) != sample rate * block align")
        }
        guard data.size % UInt64(blockAlign) == 0 else {
            throw AudioError(.invalidFormat, path, "data length \(data.size) is not a multiple of block align \(blockAlign)")
        }
        return WAVInfo(encoding: encoding, extensible: extensible, channels: channels, sampleRateHz: rate,
                       blockAlign: blockAlign, dataOffset: data.offset, dataBytes: data.size,
                       frameCount: Int64(data.size / UInt64(blockAlign)), fileBytes: fileBytes,
                       trailingBytes: fileBytes - riffEnd)
    }

    static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }

    static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
