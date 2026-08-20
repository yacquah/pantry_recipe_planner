import Foundation

/// Time-ordered UUIDs (RFC 9562 §5.7).
///
/// ADR 005 requires the *client* to mint identifiers rather than the database.
/// The reason is sync: when a response is lost the client retries, and only an
/// id the server did not invent lets it upsert instead of writing a second
/// decrement. An auto-increment primary key structurally cannot do this.
///
/// Version 7 rather than the more familiar version 4 because the first 48 bits
/// are a millisecond timestamp, so ids sort into creation order. For a table
/// that is an append-only log, that is worth having for free.
public enum UUIDv7 {

    /// Layout, 128 bits total:
    ///
    ///     48  unix time in milliseconds
    ///      4  version (0b0111)
    ///     12  random
    ///      2  variant (0b10)
    ///     62  random
    public static func generate(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)

        let milliseconds = UInt64(date.timeIntervalSince1970 * 1000)
        bytes[0] = UInt8((milliseconds >> 40) & 0xFF)
        bytes[1] = UInt8((milliseconds >> 32) & 0xFF)
        bytes[2] = UInt8((milliseconds >> 24) & 0xFF)
        bytes[3] = UInt8((milliseconds >> 16) & 0xFF)
        bytes[4] = UInt8((milliseconds >> 8) & 0xFF)
        bytes[5] = UInt8(milliseconds & 0xFF)

        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255)
        }

        // Overwrite the version and variant bits, preserving the random bits
        // sharing those bytes.
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let characters = Array(hex)
        return String(characters[0..<8])   + "-"
             + String(characters[8..<12])  + "-"
             + String(characters[12..<16]) + "-"
             + String(characters[16..<20]) + "-"
             + String(characters[20..<32])
    }
}

/// The database stores timestamps as ISO-8601 text, matching the seed data.
public enum Timestamp {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    public static func instant(_ date: Date = Date()) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss").string(from: date)
    }

    public static func day(_ date: Date = Date()) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }
}
