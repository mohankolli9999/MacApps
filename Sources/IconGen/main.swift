import AppKit
import SwiftUI

// The app icon, drawn rather than painted, so it can be edited in the same
// language as the app and re-rendered at every size from one vector source.
//
// Concept: a treemap cut down to the fewest regions that still are one — mass,
// quiet mass, and the space where a third used to be. The space is not outlined.
// It is a well with light in it, and the light falls on the faces around it, so
// what the icon shows is not a missing rectangle but room opening up.
//
// Five coloured cells read as a chart. Two chromatic voices and one light source
// read as an object, which is what sits in a Dock next to Finder all day.

enum Palette {
    /// The field. Colder and deeper than the app's own stage, because an icon is
    /// looked at against every wallpaper there is and has to hold its own edge.
    static let abyss = Color(hex: 0x061219)
    static let shelf = Color(hex: 0x0F2B37)
    /// The mass that stays. The app's indigo, pulled colder to sit under the beam.
    static let flow = Color(hex: 0x5C6FE8)
    /// What comes out of the void. Near-white at the core so it reads as light
    /// rather than as another coloured block.
    static let beam = Color(hex: 0x8FF3FF)
    static let keyline = Color(hex: 0xE6EEF0)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Measured off Notes, Calculator and Terminal on macOS 26.4.1: every system
/// icon is an 824pt body centred on a 1024pt canvas, leaving 100pt for the
/// shadow to fall into. The corner is Apple's continuous curve, not a circular
/// arc — its flatten point sits at ~1.19x the nominal radius, which is why a
/// naive measurement of the artwork reads 221 rather than 185.4.
enum Grid {
    static let canvas: CGFloat = 1024
    static let body: CGFloat = 824
    static let corner: CGFloat = 185.4
    static let margin: CGFloat = (canvas - body) / 2
    /// Breathing room between the treemap and the squircle edge.
    static let padding: CGFloat = 104
    static var map: CGFloat { body - padding * 2 }
}

private struct Cell {
    let x, y, w, h: CGFloat
    enum Surface { case mass, quiet, reclaimed }
    let surface: Surface
}

/// Three regions at proportions no grid would produce. An even split reads as a
/// layout template; the whole claim of a treemap is that the sizes are unequal
/// and mean something, and the icon has to make that claim in one glance.
private let cells: [Cell] = [
    Cell(x: 0, y: 0, w: 0.440, h: 0.560, surface: .mass),
    Cell(x: 0, y: 0.590, w: 0.440, h: 0.410, surface: .quiet),
    Cell(x: 0.470, y: 0, w: 0.530, h: 1.000, surface: .reclaimed),
]

struct IconView: View {
    /// The size this render is destined for. Detail that reads at 512 becomes
    /// noise at 32, so the artwork simplifies itself rather than being downsampled
    /// into mush — which is why Apple ships separate small representations.
    let pixels: CGFloat

    private var isSmall: Bool { pixels < 128 }
    /// At 16pt a stroke that lands on a device pixel is a quarter of the cell it
    /// is drawing, so an outlined void closes up into a bright smear. Below this
    /// the void is filled instead: nobody perceives a hole at that size, and a
    /// lit block in the same place is the same object seen from further away.
    private var isTiny: Bool { pixels < 32 }

    /// Smallest stroke that still lands on a whole device pixel at this size.
    private var minStroke: CGFloat { 1.25 * Grid.canvas / pixels }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Grid.corner, style: .continuous)
                .fill(LinearGradient(colors: [Palette.shelf, Palette.abyss],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                // A single soft specular along the top edge is what makes a flat
                // shape read as a macOS icon rather than a sticker.
                .overlay {
                    RoundedRectangle(cornerRadius: Grid.corner, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                     startPoint: .top,
                                                     endPoint: .center),
                                      lineWidth: 3)
                }
                .frame(width: Grid.body, height: Grid.body)
                .shadow(color: .black.opacity(0.38), radius: 26, y: 16)

            treemap
                .frame(width: Grid.map, height: Grid.map)
        }
        .frame(width: Grid.canvas, height: Grid.canvas)
    }

    /// The void is drawn last so its light falls across the blocks beside it
    /// rather than under them. Nothing else in the icon casts anything.
    private var treemap: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                let w = cell.w * side
                let h = cell.h * side
                // Radius tracks cell size: one radius on everything is the tell
                // that the blocks are decoration rather than data.
                let radius = min(w, h) * 0.085

                Group {
                    switch cell.surface {
                    case .mass: massCell(radius: radius)
                    case .quiet: quietCell(radius: radius)
                    case .reclaimed: voidCell(radius: radius, size: CGSize(width: w, height: h))
                    }
                }
                .frame(width: w, height: h)
                .offset(x: cell.x * side, y: cell.y * side)
            }
        }
    }

    /// What stays. Lit from the void's side, not from above, so the two shapes
    /// belong to one scene instead of sitting next to each other.
    private func massCell(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [Palette.flow.opacity(0.72), Palette.flow],
                                 startPoint: .leading,
                                 endPoint: .trailing))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.clear, Palette.beam.opacity(0.55)],
                                                 startPoint: .leading,
                                                 endPoint: .trailing),
                                  lineWidth: max(Grid.canvas * 0.0035, minStroke))
            }
    }

    private func quietCell(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.keyline.opacity(0.13))
            .overlay(alignment: .top) {
                // The face nearest the void catches it; the rest of the block
                // does not. One light source is what stops this reading flat.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Palette.beam.opacity(0.42), .clear],
                                                 startPoint: .top,
                                                 endPoint: .center),
                                  lineWidth: max(Grid.canvas * 0.003, minStroke))
            }
    }

    /// Not an outlined empty rectangle — a well with light coming out of it. The
    /// far wall is lost in the dark, the near edges catch the beam, and a little
    /// of it spills onto the neighbours. That is the difference between an icon
    /// that says "one block is missing" and one that says "there is room here".
    ///
    /// The spill and the falloff are the first things to go below 128px, where
    /// they smear into a bright blur and lose the hole. What survives is a crisp
    /// keyline: at Dock size the story is a lit rectangle against a solid one.
    private func voidCell(radius: CGFloat, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(isTiny ? Palette.beam.opacity(0.88) : Palette.abyss)

            if !isSmall {
                // Rising from the corner nearest the mass, so the light on that
                // block's edge has somewhere to have come from.
                shape.fill(RadialGradient(colors: [Palette.beam.opacity(0.30),
                                                   Palette.beam.opacity(0.06),
                                                   .clear],
                                          center: .bottomLeading,
                                          startRadius: 0,
                                          endRadius: size.height * 0.78))
            }

            if !isTiny {
                shape.strokeBorder(
                    LinearGradient(colors: [Palette.beam.opacity(isSmall ? 0.55 : 0.20),
                                            Palette.beam.opacity(isSmall ? 0.95 : 1.0)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: max(size.width * 0.022, minStroke))
            }
        }
        .compositingGroup()
        .shadow(color: Palette.beam.opacity(isSmall ? 0 : 0.5),
                radius: size.width * 0.10)
    }
}

@MainActor
func render(pixels: Int) -> Data {
    let renderer = ImageRenderer(content: IconView(pixels: CGFloat(pixels)))
    renderer.proposedSize = ProposedViewSize(width: Grid.canvas, height: Grid.canvas)
    // Render from the vector at each size rather than downscaling one master:
    // the 16pt icon keeps clean edges instead of inheriting resample mush.
    renderer.scale = CGFloat(pixels) / Grid.canvas

    guard let cgImage = renderer.cgImage else { fatalError("icon render produced nothing") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("icon PNG encoding failed")
    }
    return png
}

@main
enum IconGen {
    /// The ten representations `iconutil` requires for a complete .icns.
    static let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("Resources")
        let iconset = resources.appendingPathComponent("DiskReclaim.iconset")

        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for (name, pixels) in sizes {
            try render(pixels: pixels)
                .write(to: iconset.appendingPathComponent("\(name).png"))
        }
        // A full-resolution copy for README and store artwork.
        try render(pixels: 1024)
            .write(to: resources.appendingPathComponent("DiskReclaim-1024.png"))

        let icns = resources.appendingPathComponent("DiskReclaim.icns")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        convert.arguments = ["--convert", "icns", iconset.path, "--output", icns.path]
        try convert.run()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("iconutil failed\n".utf8))
            exit(1)
        }

        try FileManager.default.removeItem(at: iconset)
        print(icns.path)
    }
}
