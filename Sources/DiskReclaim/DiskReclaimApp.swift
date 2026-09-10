import SwiftUI

@main
struct DiskReclaimApp: App {
    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`: this app has one view of
        // one machine, so a second window would be a copy with nothing to say.
        // It also makes the Dock icon reopen a closed window, which a WindowGroup
        // with `.newItem` suppressed does not — that combination strands the app
        // running with no way to get it back.
        Window("Disk Reclaim", id: "main") {
            ContentView()
                .preferredColorScheme(.dark)
                .background(WindowPlacer())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1020, height: 700)
        .windowResizability(.contentMinSize)
    }
}

/// Opens the window on the screen the pointer is on.
///
/// `.defaultPosition(.center)` centres on whichever screen AppKit ranks first,
/// which on a machine with a virtual or headless display can be a screen nobody
/// is looking at — the window then opens correctly onto nothing and the app
/// reads as broken. The pointer is the one reliable signal for where the user is.
private struct WindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }

            var frame = window.frame
            frame.origin = CGPoint(x: visible.midX - frame.width / 2,
                                   y: visible.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
