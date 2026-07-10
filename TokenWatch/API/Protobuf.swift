//
//  Protobuf.swift
//  TokenWatch
//
//  스키마 없이 protobuf wire 포맷을 읽는 최소 리더 + gRPC-web 프레임 추출기.
//  (Grok GetGrokCreditsConfig 같은 gRPC-web/Connect 응답을 파싱할 때 사용.
//   .proto 스키마가 없어 필드 번호를 모르므로, 숫자 leaf를 수집해 휴리스틱으로 해석한다.)
//
//  wire type: 0=varint, 1=64-bit(fixed64/double), 2=length-delimited, 5=32-bit(fixed32/float)
//

import Foundation

enum Protobuf {

    /// 파싱된 필드 하나(스칼라 값 또는 length-delimited 바이트).
    struct Field {
        let number: Int
        let wireType: Int
        let varint: UInt64?     // wire 0
        let fixed64: UInt64?    // wire 1
        let fixed32: UInt32?    // wire 5
        let bytes: Data?        // wire 2
    }

    /// 최상위 필드들을 파싱한다. 형식이 어긋나면 그 지점까지만 반환.
    static func fields(_ data: Data) -> [Field] {
        var out: [Field] = []
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            guard let (tag, ni) = readVarint(b, i) else { break }
            i = ni
            let number = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            guard number > 0 else { break }
            switch wire {
            case 0:
                guard let (v, n) = readVarint(b, i) else { return out }
                i = n
                out.append(Field(number: number, wireType: 0, varint: v, fixed64: nil, fixed32: nil, bytes: nil))
            case 1:
                guard i + 8 <= b.count else { return out }
                let v = readFixed(b, i, 8)
                i += 8
                out.append(Field(number: number, wireType: 1, varint: nil, fixed64: v, fixed32: nil, bytes: nil))
            case 2:
                guard let (len, n) = readVarint(b, i) else { return out }
                let start = n, end = n + Int(len)
                guard end <= b.count else { return out }
                i = end
                out.append(Field(number: number, wireType: 2, varint: nil, fixed64: nil, fixed32: nil,
                                 bytes: Data(b[start..<end])))
            case 5:
                guard i + 4 <= b.count else { return out }
                let v = UInt32(truncatingIfNeeded: readFixed(b, i, 4))
                i += 4
                out.append(Field(number: number, wireType: 5, varint: nil, fixed64: nil, fixed32: v, bytes: nil))
            default:
                return out   // 알 수 없는 wire type → 중단
            }
        }
        return out
    }

    /// gRPC-web 응답에서 첫 메시지 프레임의 payload를 꺼낸다.
    /// 프레임 = [flag 1B][length 4B big-endian][payload]. flag의 0x80비트는 trailer.
    static func grpcWebMessage(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var i = 0
        while i + 5 <= b.count {
            let flag = b[i]
            let len = (Int(b[i+1]) << 24) | (Int(b[i+2]) << 16) | (Int(b[i+3]) << 8) | Int(b[i+4])
            let start = i + 5, end = start + len
            guard end <= b.count else { break }
            if flag & 0x80 == 0 {           // trailer가 아니면 메시지 프레임.
                return Data(b[start..<end])
            }
            i = end
        }
        // 프레이밍이 없으면(raw proto) 원본을 그대로 시도.
        return data.isEmpty ? nil : data
    }

    /// 메시지에서 숫자 leaf를 재귀 수집한다(휴리스틱 해석용).
    /// - doubles: fixed64를 double로, fixed32를 float으로 해석한 값
    /// - varints: wire 0 정수값
    static func collectNumbers(_ data: Data, depth: Int = 0) -> (doubles: [Double], varints: [UInt64]) {
        var doubles: [Double] = []
        var varints: [UInt64] = []
        for f in fields(data) {
            if let v = f.varint { varints.append(v) }
            if let x = f.fixed64 { doubles.append(Double(bitPattern: x)) }
            if let x = f.fixed32 { doubles.append(Double(Float(bitPattern: x))) }
            if let sub = f.bytes, depth < 3, looksLikeMessage(sub) {
                let r = collectNumbers(sub, depth: depth + 1)
                doubles.append(contentsOf: r.doubles)
                varints.append(contentsOf: r.varints)
            }
        }
        return (doubles, varints)
    }

    // MARK: 내부

    /// 바이트열이 온전한 protobuf 메시지로 파싱되면 true(중첩 메시지 추정).
    private static func looksLikeMessage(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            guard let (tag, ni) = readVarint(b, i) else { return false }
            i = ni
            let number = Int(tag >> 3), wire = Int(tag & 0x7)
            guard number > 0 else { return false }
            switch wire {
            case 0: guard let (_, n) = readVarint(b, i) else { return false }; i = n
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let (len, n) = readVarint(b, i) else { return false }
                i = n + Int(len)
            default: return false
            }
            if i > b.count { return false }
        }
        return true
    }

    private static func readVarint(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < b.count {
            let byte = b[i]
            result |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private static func readFixed(_ b: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<count { v |= UInt64(b[start + k]) << (8 * k) }  // little-endian
        return v
    }
}
