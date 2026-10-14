import Foundation

// Packaging may discard symbol names, never executable instructions, Swift
// metadata, UI constants or data. This reads actual packaged Mach-O bytes.
struct Section: Equatable { let bytes: Data; let size: UInt64; let type: UInt32 }
func sections(_ filename: String) throws -> [String: Section] {
    let data = try Data(contentsOf: URL(fileURLWithPath: filename))
    func u32(_ p: Int) -> UInt32 {
        precondition(p >= 0 && p + 4 <= data.count)
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt32.self)) }
    }
    func u64(_ p: Int) -> UInt64 {
        precondition(p >= 0 && p + 8 <= data.count)
        return data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt64.self)) }
    }
    func name(_ p: Int) -> String {
        String(decoding: data[p..<(p + 16)].prefix { $0 != 0 }, as: UTF8.self)
    }
    precondition(u32(0) == 0xfeedfacf, "Expected native thin 64-bit Mach-O")
    var result: [String: Section] = [:], p = 32
    for _ in 0..<u32(16) {
        let commandSize = Int(u32(p + 4))
        precondition(commandSize >= 8 && p + commandSize <= data.count)
        if u32(p) == 0x19 {
            let count = Int(u32(p + 64))
            precondition(72 + count * 80 <= commandSize)
            for i in 0..<count {
                let s = p + 72 + i * 80, size = u64(s + 40)
                let offset = Int(u32(s + 48)), type = u32(s + 64) & 0xff
                let zeroFill = [UInt32(1), 0xc, 0x12].contains(type)
                precondition(zeroFill || (size <= UInt64(data.count) && offset <= data.count - Int(size)))
                let bytes = zeroFill ? Data() : data.subdata(in: offset..<(offset + Int(size)))
                let key = name(s + 16) + "/" + name(s)
                precondition(result[key] == nil)
                result[key] = Section(bytes: bytes, size: size, type: type)
            }
        }
        p += commandSize
    }
    return result
}
let before = try sections(CommandLine.arguments[1]), after = try sections(CommandLine.arguments[2])
guard !before.isEmpty, before == after else {
    print("FAIL: packaging changed executable code, metadata or data"); exit(1)
}
print("PASS: all \(before.count) runtime sections remain byte-identical")
