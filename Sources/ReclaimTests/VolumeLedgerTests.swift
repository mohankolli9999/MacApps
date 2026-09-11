import Foundation
import ReclaimCore

/// Shaped exactly like `diskutil apfs list -plist` on this machine, trimmed to
/// the keys the ledger reads. The disk3 figures are real, so the residual the
/// test asserts is the residual the machine actually has.
private let containerFixture = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Containers</key>
  <array>
    <dict>
      <key>ContainerReference</key><string>disk3</string>
      <key>CapacityCeiling</key><integer>494384795648</integer>
      <key>CapacityFree</key><integer>46468136960</integer>
      <key>Volumes</key>
      <array>
        <dict>
          <key>DeviceIdentifier</key><string>disk3s1</string>
          <key>Name</key><string>Macintosh HD</string>
          <key>CapacityInUse</key><integer>17264533504</integer>
          <key>Roles</key><array><string>System</string></array>
        </dict>
        <dict>
          <key>DeviceIdentifier</key><string>disk3s2</string>
          <key>Name</key><string>Preboot</string>
          <key>CapacityInUse</key><integer>18028351488</integer>
          <key>Roles</key><array><string>Preboot</string></array>
        </dict>
        <dict>
          <key>DeviceIdentifier</key><string>disk3s3</string>
          <key>Name</key><string>Recovery</string>
          <key>CapacityInUse</key><integer>2653257728</integer>
          <key>Roles</key><array><string>Recovery</string></array>
        </dict>
        <dict>
          <key>DeviceIdentifier</key><string>disk3s4</string>
          <key>Name</key><string>Update</string>
          <key>CapacityInUse</key><integer>807370752</integer>
          <key>Roles</key><array><string>Update</string></array>
        </dict>
        <dict>
          <key>DeviceIdentifier</key><string>disk3s5</string>
          <key>Name</key><string>Data</string>
          <key>CapacityInUse</key><integer>406854934528</integer>
          <key>Roles</key><array><string>Data</string></array>
        </dict>
        <dict>
          <key>DeviceIdentifier</key><string>disk3s6</string>
          <key>Name</key><string>VM</string>
          <key>CapacityInUse</key><integer>2147835904</integer>
          <key>Roles</key><array><string>VM</string></array>
        </dict>
      </array>
    </dict>
    <dict>
      <key>ContainerReference</key><string>disk6</string>
      <key>CapacityCeiling</key><integer>131031040</integer>
      <key>CapacityFree</key><integer>63025152</integer>
      <key>Volumes</key>
      <array>
        <dict>
          <key>DeviceIdentifier</key><string>disk6s1</string>
          <key>Name</key><string>Ghostty</string>
          <key>CapacityInUse</key><integer>66621440</integer>
          <key>Roles</key><array/>
        </dict>
      </array>
    </dict>
  </array>
</dict>
</plist>
"""

private let snapshotFixture = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Snapshots</key>
  <array>
    <dict>
      <key>SnapshotUUID</key><string>EC42DB08-666B-469F-AF88-B6ED8A25E783</string>
      <key>SnapshotName</key><string>com.apple.os.update-7D0A8EB9</string>
      <key>SnapshotXID</key><integer>17067010</integer>
      <key>Purgeable</key><false/>
    </dict>
    <dict>
      <key>SnapshotUUID</key><string>1BAEDCEC-5A16-4590-9D51-E5EA866C2F96</string>
      <key>SnapshotName</key><string>com.apple.TimeMachine.2026-09-10-084500.local</string>
      <key>SnapshotXID</key><integer>20629357</integer>
      <key>Purgeable</key><true/>
    </dict>
  </array>
</dict>
</plist>
"""

@MainActor func runVolumeLedgerTests(_ t: Harness) {
    t.section("Volume ledger — containers")

    let containers = try! VolumeLedger.containers(fromPlist: Data(containerFixture.utf8))
    t.equal(containers.count, 2, "both containers parsed")

    let boot = containers[0]
    t.equal(boot.device, "disk3", "container names its device")
    t.equal(boot.volumes.count, 6, "every volume in the container parsed")
    t.equal(boot.usedByVolumesBytes, 447_756_283_904, "volume usage sums")

    // Ceiling 494,384,795,648 − free 46,468,136,960 − volumes 447,756,283,904.
    // APFS keeps checkpoints and space-manager metadata outside every volume,
    // and no folder walk will ever find these bytes.
    t.equal(boot.unaccountedBytes, 160_374_784, "container residual is named, not lost")

    let dmg = containers[1]
    t.equal(dmg.unaccountedBytes, 131_031_040 - 63_025_152 - 66_621_440,
            "residual is arithmetic, not a constant")

    t.section("Volume ledger — hidden volumes")

    let hidden = boot.volumes.filter(\.isHidden).map(\.name)
    t.equal(hidden, ["Preboot", "Recovery", "Update", "VM"],
            "the volumes Finder never shows are the ones reported hidden")
    t.equal(boot.volumes.filter(\.isHidden).reduce(0) { $0 + $1.usedBytes }, 23_636_815_872,
            "hidden volumes carry their bytes")
    t.expect(!dmg.volumes[0].isHidden, "a mounted image with no role is browsable")
    t.expect(boot.volumes.first { $0.name == "Data" }?.isHidden == false,
             "the Data volume is what the user browses, not a hidden one")

    t.section("Volume ledger — snapshots")

    let snaps = try! VolumeLedger.snapshots(fromPlist: Data(snapshotFixture.utf8))
    t.equal(snaps.count, 2, "both snapshots parsed")
    t.equal(snaps[0].name, "com.apple.os.update-7D0A8EB9", "snapshot names itself")
    t.equal(snaps[0].xid, 17_067_010, "snapshot transaction id parsed")
    t.expect(!snaps[0].isPurgeable, "an OS update snapshot is not purgeable")
    t.expect(snaps[1].isPurgeable, "a local Time Machine snapshot is purgeable")

    let none = try! VolumeLedger.snapshots(fromPlist: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Snapshots</key><array/></dict></plist>
        """.utf8))
    t.equal(none.count, 0, "a volume with no snapshots reads as none, not as an error")

    t.section("Volume ledger — malformed input")

    // diskutil's output is another program's output. Treating a truncated or
    // reshaped answer as zero bytes would silently shrink the disk.
    t.expect((try? VolumeLedger.containers(fromPlist: Data("not a plist".utf8))) == nil,
             "garbage is rejected, not read as an empty disk")
    t.expect((try? VolumeLedger.containers(fromPlist: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Unexpected</key><string>x</string></dict></plist>
        """.utf8))) == nil,
             "a valid plist of the wrong shape is rejected")
    t.expect((try? VolumeLedger.snapshots(fromPlist: Data("<plist></plist>".utf8))) == nil,
             "a snapshot list missing its array is rejected")

    t.section("Volume ledger — system volume mounts")

    t.expect(VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/System/Volumes/Preboot")),
             "Preboot is one of macOS's own volumes")
    t.expect(VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/System/Volumes/VM")),
             "so is VM")
    // Every one of these is mounted, non-browsable, and under the same prefix.
    // Offering them as places to look would show the boot disk's bytes a second
    // time under a second name.
    t.expect(!VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/System/Volumes/Data")),
             "the Data volume is the firmlink mirror of what is already at /")
    t.expect(!VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/System/Volumes/Update/mnt1")),
             "an installer's second mount of the boot disk is not a volume of its own")
    t.expect(!VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/System/Volumes/Update/SFR/mnt1")),
             "nor is the staged recovery image")
    t.expect(!VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/System/Volumes/Data/home")),
             "nor is the autofs home mount")
    t.expect(!VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/")),
             "the boot volume is not hidden")
    t.expect(!VolumeLedger.isSystemVolumeMount(URL(fileURLWithPath: "/Volumes/Ghostty")),
             "a mounted disk image is not one of macOS's own")

    t.section("Volume ledger — argument boundary")

    // diskutil reads options and device identifiers from the same argument
    // position, so anything starting with a dash becomes a flag.
    t.expect(VolumeLedger.isDeviceIdentifier("disk3"), "a container reference is an identifier")
    t.expect(VolumeLedger.isDeviceIdentifier("disk3s5"), "a volume is an identifier")
    t.expect(VolumeLedger.isDeviceIdentifier("disk3s1s1"), "a snapshot mount is an identifier")
    t.expect(!VolumeLedger.isDeviceIdentifier("-force"), "a flag is not an identifier")
    t.expect(!VolumeLedger.isDeviceIdentifier("disk3; rm -rf /"), "a shell fragment is not an identifier")
    t.expect(!VolumeLedger.isDeviceIdentifier("/dev/disk3"), "a device path is not an identifier")
    t.expect(!VolumeLedger.isDeviceIdentifier(""), "empty is not an identifier")
    t.expect(!VolumeLedger.isDeviceIdentifier("diskX"), "a name without a number is not an identifier")

    t.section("Volume ledger — purgeable")

    // The boot volume is the only one the filesystem answers for; every other
    // mount reports zero important-usage, and subtracting from that gives a
    // negative number the size of the whole disk.
    for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                     options: []) ?? [] {
        guard let purgeable = VolumeLedger.purgeableBytes(at: url) else { continue }
        t.expect(purgeable >= 0, "purgeable at \(url.path) is a size, not a deficit")
    }
    t.expect(VolumeLedger.purgeableBytes(at: URL(fileURLWithPath: "/definitely/not/mounted")) == nil,
             "an unmounted path reports nothing rather than zero")
}

@MainActor func runByteFormatTests(_ t: Harness) {
    t.section("Byte format")

    // Finder calls this disk 494.38 GB. Dividing by 1024 and printing "GB" is
    // how a disk tool ends up disagreeing with the Finder window beside it.
    t.equal(ByteFormat.decimal.string(494_384_795_648), "494 GB", "decimal matches what Finder shows")
    t.equal(ByteFormat.binary.string(494_384_795_648), "460 GiB", "binary says GiB when it divides by 1024")

    t.equal(ByteFormat.decimal.string(0), "0 B", "zero is zero in either base")
    t.equal(ByteFormat.binary.string(0), "0 B", "zero is zero in either base")
    t.equal(ByteFormat.decimal.string(999), "999 B", "below a kilobyte stays in bytes")
    t.equal(ByteFormat.decimal.string(1_000), "1.0 KB", "a decimal kilobyte is a thousand")
    t.equal(ByteFormat.binary.string(1_023), "1023 B", "a binary kilobyte is not a thousand")
    t.equal(ByteFormat.binary.string(1_024), "1.0 KiB", "a binary kilobyte is 1024")
    t.equal(ByteFormat.decimal.string(1_348_448_320), "1.3 GB", "small values keep a decimal place")
    t.equal(ByteFormat.decimal.string(-5), "0 B", "a negative size is not a size")
}

@MainActor func runAccessProbeTests(_ t: Harness) {
    t.section("Full disk access — denied is not absent")

    let readable = FileManager.default.temporaryDirectory
        .appendingPathComponent("ledger-probe-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: readable) }

    let absent = "/definitely/not/a/real/path"
    // Guarded for every app on every Mac, and present on every Mac, which is
    // what makes a refusal here mean refused rather than missing.
    let guarded = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"

    t.equal(FullDiskAccess.check(paths: [readable.path]), .granted,
            "a directory that lists is access")
    t.equal(FullDiskAccess.check(paths: [absent]), .unknown,
            "a path that is not there proves nothing either way")
    t.equal(FullDiskAccess.check(paths: [absent, readable.path]), .granted,
            "one readable path is enough")
    t.equal(FullDiskAccess.check(paths: []), .unknown,
            "nothing to probe is not a denial")

    // The old probe returned false here and the app told the user to grant a
    // permission they may already have had.
    t.equal(FullDiskAccess.check(paths: [guarded]),
            FullDiskAccess.check(paths: [guarded, absent]),
            "adding a missing path does not change the verdict")

    let verdict = FullDiskAccess.check(paths: [guarded])
    t.expect(verdict != .unknown,
             "the TCC directory exists on every Mac, so it always answers granted or denied")
}

@MainActor func runVolumeSpaceTests(_ t: Harness) {
    t.section("Volume space")

    // The window has to say something true before the first branch lands. A walk
    // is a minute; this is a syscall, and an empty frame for that minute is the
    // whole of what "the app is slow" describes.
    do {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let space = VolumeLedger.space(at: home) else {
            t.expect(false, "the volume the home folder is on can be measured")
            return
        }
        t.expect(space.capacity > 0, "a mounted volume has a size")
        t.expect(space.free >= 0, "and a non-negative amount left")
        t.expect(space.free <= space.capacity, "which cannot exceed the size")
        t.equal(space.used, space.capacity - space.free, "used is what is not free")
    }

    do {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-volume-\(UUID().uuidString)")
        t.expect(VolumeLedger.space(at: missing) == nil,
                 "somewhere that is not there reports nothing rather than zero")
    }
}
