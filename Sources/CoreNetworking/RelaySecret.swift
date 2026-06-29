import Foundation

/// A short, URL-safe secret the TV generates per auth attempt and carries inside
/// the relay auth QR. The relay binds the redeem code to it, so the 4-digit code
/// shown to the user can't be brute-forced — redeeming also requires this secret.
public enum RelaySecret {
    /// 32 URL-safe characters (~190 bits) — never reused across attempts.
    public static func generate(length: Int = 32) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
    }
}
