import Foundation

public enum SMBPath {
    // Apple SMB maps reserved punctuation to the SFM private Unicode range.
    // Decode only display/search fields; keep wire paths intact for identity and I/O.
    static let punctuation: [(UInt32, UInt32)] = [
        (0xF020, 0x22), (0xF021, 0x2A), (0xF022, 0x3A), (0xF023, 0x3C),
        (0xF024, 0x3E), (0xF025, 0x3F), (0xF026, 0x5C), (0xF027, 0x7C)
    ]
    public static func display(_ path: String) -> String {
        let mapping = Dictionary(uniqueKeysWithValues: punctuation)
        return String(String.UnicodeScalarView(path.unicodeScalars.map { scalar in
            mapping[scalar.value].flatMap(UnicodeScalar.init) ?? scalar
        }))
    }
}
