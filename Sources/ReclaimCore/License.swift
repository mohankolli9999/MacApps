import CryptoKit
import Foundation

/// Who bought the app, proven by a signature rather than by asking a server.
public struct License: Sendable, Equatable, Codable {
    public let name: String
    public let email: String
    public let issued: Date
    /// The order it came from. The only field the buyer did not write, and the
    /// one that identifies a key that has leaked or been refunded.
    public let order: String

    public init(name: String, email: String, issued: Date, order: String) {
        self.name = name
        self.email = email
        self.issued = issued
        self.order = order
    }
}

public enum LicenseFault: Error, Equatable {
    /// Not three dot-separated parts, or a part that is not base64url.
    case malformed
    /// A key issued for a version of the format this build does not know.
    case unknownFormat(String)
    /// Well-formed and signed by somebody else — or edited after signing.
    case forged
}

/// Checks licence keys. Cannot issue them: the half of the keypair that signs
/// never exists on a customer's machine, which is what makes an offline check
/// worth anything.
///
/// A key is `DRCL1.<payload>.<signature>`, both parts base64url. The signature
/// covers the payload *as written*, so verification never has to re-encode
/// anything and there is no canonical-form argument to lose.
public enum LicenseAuthority {
    public static let prefix = "DRCL1"

    /// Ed25519, raw 32 bytes. Public by design — it proves nothing and unlocks
    /// nothing. Replacing it invalidates every key ever issued, which is the
    /// recovery path if the private half is ever lost or leaked.
    public static let publicKeyBase64 = "XB8dg6f1E6Agjg6Ag7TYBOQk5l/9e8xFM0u45N5xg/M="

    public static func verify(_ text: String,
                              publicKey: String = publicKeyBase64) throws -> License {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3 else { throw LicenseFault.malformed }
        guard parts[0] == prefix else { throw LicenseFault.unknownFormat(String(parts[0])) }

        guard let payload = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2]))
        else { throw LicenseFault.malformed }

        guard let raw = Data(base64Encoded: publicKey),
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              signer.isValidSignature(signature, for: Data(parts[1].utf8))
        else { throw LicenseFault.forged }

        guard let claim = try? JSONDecoder().decode(Claim.self, from: payload) else {
            throw LicenseFault.malformed
        }
        return License(name: claim.n, email: claim.e,
                       issued: Date(timeIntervalSince1970: TimeInterval(claim.d)),
                       order: claim.o)
    }

    /// Signs one. Only ever called by the issuing tool, which is why the private
    /// key arrives as an argument instead of living anywhere in this module.
    public static func issue(_ license: License, privateKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKeyBase64) else { throw LicenseFault.malformed }
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        let claim = Claim(n: license.name, e: license.email,
                          d: Int(license.issued.timeIntervalSince1970), o: license.order)
        // Sorted keys so the payload is stable across runs. The signature is not:
        // CryptoKit randomises the nonce, so a reissue is a different string for
        // the same licence. Compare licences, never the strings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = Base64URL.encode(try encoder.encode(claim))
        let signature = try signer.signature(for: Data(payload.utf8))
        return "\(prefix).\(payload).\(Base64URL.encode(signature))"
    }

    /// Short field names because the whole thing ends up as a string somebody
    /// pastes out of an email.
    private struct Claim: Codable {
        let n: String
        let e: String
        let d: Int
        let o: String
    }
}

/// Plain base64 with `+/=` in it survives a round trip through most software and
/// gets mangled by the rest, and a licence key spends its life in email bodies
/// and web forms.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

/// What the app will do for somebody who has not bought it yet.
///
/// Measuring is never gated. A disk tool that will not tell you what is on your
/// own disk until you pay has nothing to sell, because the measurement is the
/// part you have to trust before you would hand it a delete button.
public enum Entitlement: Sendable, Equatable {
    case licensed(License)
    case trial(used: Int64, allowance: Int64)
    case spent(allowance: Int64)

    public var canReclaim: Bool {
        if case .spent = self { return false }
        return true
    }

    public var remaining: Int64 {
        switch self {
        case .licensed: .max
        case .trial(let used, let allowance): allowance - used
        case .spent: 0
        }
    }
}

public enum Entitlements {
    /// A trial counted in bytes freed rather than days elapsed. The app is worth
    /// nothing to somebody who has not yet found anything worth removing, and a
    /// clock that runs down while they are on holiday is a worse first
    /// impression than any paywall.
    public static let trialAllowance: Int64 = 5 << 30

    /// The ledger is the restore manifest, which is written before every removal
    /// because it is the only way back. Deleting it to reset the trial also
    /// deletes every way back, which is a price nobody pays twice.
    public static func reclaimed(from manifest: ManifestStore) -> Int64 {
        ((try? manifest.all()) ?? []).reduce(0) { $0 + $1.bytesFreed }
    }

    public static func current(license: License?,
                               reclaimed: Int64,
                               allowance: Int64 = trialAllowance) -> Entitlement {
        if let license { return .licensed(license) }
        return reclaimed >= allowance ? .spent(allowance: allowance)
                                      : .trial(used: max(0, reclaimed), allowance: allowance)
    }
}

/// Where the accepted key sits between launches.
///
/// The file is not the authority. Every launch re-verifies what it finds, so
/// hand-editing it produces an unlicensed app rather than a free one.
public struct LicenseStore: Sendable {
    public let url: URL
    public let publicKey: String

    public init(url: URL, publicKey: String = LicenseAuthority.publicKeyBase64) {
        self.url = url
        self.publicKey = publicKey
    }

    public static var standard: LicenseStore {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LicenseStore(url: support.appendingPathComponent("DiskReclaim/license"))
    }

    public func load() -> License? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? LicenseAuthority.verify(text, publicKey: publicKey)
    }

    /// Verifies before writing, so a rejected key never reaches the disk and the
    /// stored file is always one that worked at least once.
    @discardableResult
    public func save(_ text: String) throws -> License {
        let license = try LicenseAuthority.verify(text, publicKey: publicKey)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: url, atomically: true, encoding: .utf8)
        return license
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
