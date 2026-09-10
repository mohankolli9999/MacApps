import CryptoKit
import Foundation
import ReclaimCore

// The vendor's half of the licensing scheme. Never bundled into the app: the
// whole point of signing licences is that the machine checking one cannot mint
// one, and shipping this alongside would hand every customer a key press away
// from the private key's job.

let defaultKeyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".diskreclaim-signing.key")

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let at = args.firstIndex(of: "--\(name)"), at + 1 < args.count else { return nil }
    return args[at + 1]
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "keygen":
    let path = option("out", in: args).map { URL(fileURLWithPath: $0) } ?? defaultKeyPath
    if FileManager.default.fileExists(atPath: path.path) {
        die("\(path.path) already exists. Every licence ever issued was signed with it — "
            + "move it aside deliberately, not by accident.")
    }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString()
        .write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    print("private  \(path.path)")
    print("public   \(key.publicKey.rawRepresentation.base64EncodedString())")
    print()
    print("Paste the public half into LicenseAuthority.publicKeyBase64 and back up the private")
    print("half offline. Losing it means reissuing every licence against a new key.")

case "issue":
    guard let name = option("name", in: args),
          let email = option("email", in: args),
          let order = option("order", in: args)
    else { die("usage: LicenseTool issue --name … --email … --order … [--key PATH]") }

    let path = option("key", in: args).map { URL(fileURLWithPath: $0) } ?? defaultKeyPath
    guard let secret = try? String(contentsOf: path, encoding: .utf8) else {
        die("no signing key at \(path.path) — run `LicenseTool keygen` first")
    }
    let license = License(name: name, email: email, issued: Date(), order: order)
    print(try LicenseAuthority.issue(license,
                                     privateKeyBase64: secret.trimmingCharacters(in: .whitespacesAndNewlines)))

case "check":
    guard args.count > 1 else { die("usage: LicenseTool check <key>") }
    do {
        let license = try LicenseAuthority.verify(args[1])
        print("valid   \(license.name) <\(license.email)>")
        print("order   \(license.order)")
        print("issued  \(license.issued.formatted(date: .abbreviated, time: .omitted))")
    } catch {
        die("rejected: \(error)")
    }

default:
    print("""
    LicenseTool — issues and checks Disk Reclaim licences.

      keygen [--out PATH]                             new signing keypair
      issue --name … --email … --order … [--key PATH] sign a licence
      check <key>                                     verify against the shipped public key
    """)
}
