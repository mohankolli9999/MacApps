import CryptoKit
import Foundation
import ReclaimCore

@MainActor func runLicenseTests(_ t: Harness) {
    t.section("Licence — signature")

    let signing = Curve25519.Signing.PrivateKey()
    let priv = signing.rawRepresentation.base64EncodedString()
    let pub = signing.publicKey.rawRepresentation.base64EncodedString()

    let issued = Date(timeIntervalSince1970: 1_757_462_400)
    let bought = License(name: "Ada Lovelace", email: "ada@example.com",
                         issued: issued, order: "ORD-4417")
    let key = try! LicenseAuthority.issue(bought, privateKeyBase64: priv)

    let read = try! LicenseAuthority.verify(key, publicKey: pub)
    t.equal(read, bought, "a signed licence reads back exactly as it was issued")

    // Ed25519 is specified as deterministic; CryptoKit's is not — it randomises
    // the nonce, so reissuing to a customer who lost their key produces a
    // different string. Same licence, so the string is never the identity.
    let reissued = try! LicenseAuthority.issue(bought, privateKeyBase64: priv)
    t.expect(reissued != key, "reissuing does not reproduce the original string")
    t.equal(try! LicenseAuthority.verify(reissued, publicKey: pub), bought,
            "but it is the same licence")

    // The point of the whole exercise: the app can check a key and cannot mint
    // one, so nothing shipped to a customer is enough to make more.
    let other = Curve25519.Signing.PrivateKey()
    let elsewhere = try! LicenseAuthority.issue(bought,
        privateKeyBase64: other.rawRepresentation.base64EncodedString())
    t.expect(rejects(elsewhere, pub) == .forged, "a licence signed by someone else is forged")

    // Editing the payload is the obvious attack: same shape, different name.
    let parts = key.split(separator: ".")
    let tampered = License(name: "Ada Lovelace", email: "mallory@example.com",
                           issued: issued, order: "ORD-4417")
    let swapped = try! LicenseAuthority.issue(tampered, privateKeyBase64: other.rawRepresentation.base64EncodedString())
    let grafted = "\(parts[0]).\(swapped.split(separator: ".")[1]).\(parts[2])"
    t.expect(rejects(grafted, pub) == .forged, "a payload swapped under a real signature is forged")

    t.expect(rejects("nonsense", pub) == .malformed, "a string that is not a key is malformed")
    t.expect(rejects("DRCL9.\(parts[1]).\(parts[2])", pub) == .unknownFormat("DRCL9"),
             "a key from a later format says so rather than guessing")

    // Keys travel through email bodies and web forms, which add whitespace and
    // choke on `+/=`.
    t.expect(!key.contains("+") && !key.contains("/") && !key.contains("="),
             "the key survives a URL and a mail client intact")
    t.equal(try! LicenseAuthority.verify("  \(key)\n", publicKey: pub), bought,
            "a pasted key keeps its meaning through the whitespace around it")

    t.section("Licence — storage")

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("licence-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = LicenseStore(url: dir.appendingPathComponent("license"), publicKey: pub)
    t.expect(store.load() == nil, "nothing stored means unlicensed")

    t.equal(try! store.save(key), bought, "saving a good key returns who it is for")
    t.equal(store.load(), bought, "and the next launch reads it back")

    var refused = false
    do { try store.save(elsewhere) } catch { refused = true }
    t.expect(refused, "a forged key is refused")
    t.equal(store.load(), bought, "and does not overwrite the one that worked")

    // The file is a cache of a decision, not the decision. Nothing in it is
    // trusted, so editing it by hand produces an unlicensed app.
    try! "\(key)x".write(to: store.url, atomically: true, encoding: .utf8)
    t.expect(store.load() == nil, "a hand-edited licence file is not a licence")

    store.clear()
    t.expect(store.load() == nil, "clearing it gives back an unlicensed app")

    // Against the key this build actually ships with — so a licence minted by
    // anyone but the vendor is exactly as useless as no licence at all.
    let shipped = LicenseStore(url: dir.appendingPathComponent("shipped"))
    var shippedRefused = false
    do { try shipped.save(key) } catch { shippedRefused = true }
    t.expect(shippedRefused, "a key the shipped build cannot verify is refused")
    t.expect(!FileManager.default.fileExists(atPath: shipped.url.path),
             "and a refused key never reaches the disk")
}

@MainActor func runEntitlementTests(_ t: Harness) {
    t.section("Entitlement")

    let bought = License(name: "Ada", email: "ada@example.com", issued: Date(), order: "ORD-1")
    let cap: Int64 = 5 << 30

    t.expect(Entitlements.current(license: bought, reclaimed: cap * 100).canReclaim,
             "a licence does not run out")
    t.equal(Entitlements.current(license: bought, reclaimed: 0), .licensed(bought),
            "and says who it belongs to")

    t.equal(Entitlements.current(license: nil, reclaimed: 0, allowance: cap),
            .trial(used: 0, allowance: cap), "a fresh install is on trial")
    t.expect(Entitlements.current(license: nil, reclaimed: cap - 1, allowance: cap).canReclaim,
             "one byte short of the cap still works")
    t.expect(!Entitlements.current(license: nil, reclaimed: cap, allowance: cap).canReclaim,
             "reaching the cap ends the trial")
    t.equal(Entitlements.current(license: nil, reclaimed: cap + 1, allowance: cap),
            .spent(allowance: cap), "and overshooting it does not read as fresh")

    // The manifest is the trial ledger, so an entry written by either half of the
    // app has to count. Reading it wrong in the lenient direction gives the app
    // away; reading it wrong in the strict direction locks out a paying customer.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("entitlement-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let manifest = ManifestStore(url: dir.appendingPathComponent("manifest.jsonl"))
    t.equal(Entitlements.reclaimed(from: manifest), 0, "no log means nothing reclaimed yet")

    let recipe = Recipe(kind: .npmCleanInstall, command: "npm ci")
    try! manifest.append(ManifestEntry(artefactID: "npm.cache", path: "/tmp/a", tier: .exact,
                                       bytesFreed: 3 << 30, recipe: recipe))
    try! manifest.append(ManifestEntry(artefactID: "storage.trash", path: "/tmp/b",
                                       tier: .irreplaceable, bytesFreed: 1 << 30,
                                       recipe: Recipe(kind: .trash, command: "Put Back")))
    t.equal(Entitlements.reclaimed(from: manifest), 4 << 30, "both halves of the app count")
    t.expect(Entitlements.current(license: nil,
                                  reclaimed: Entitlements.reclaimed(from: manifest),
                                  allowance: cap).canReclaim,
             "4 GB in, the trial has room left")
}

private func rejects(_ text: String, _ publicKey: String) -> LicenseFault? {
    do {
        _ = try LicenseAuthority.verify(text, publicKey: publicKey)
        return nil
    } catch let fault as LicenseFault {
        return fault
    } catch {
        return nil
    }
}
