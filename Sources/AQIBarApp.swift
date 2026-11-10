import SwiftUI

/// Entry point. A menu-bar-only app (no Dock icon; see LSUIElement in Info.plist).
@main
struct AQIBarApp: App {
    @StateObject private var store = AQIStore()

    init() {
        let args = CommandLine.arguments
        // `AQIBar --self-test` checks the AQI maths and exits without showing any UI.
        if args.contains("--self-test") {
            exit(SelfTest.run())
        }
        // `AQIBar --print-once [lat,lon]` loads once (station or model) and prints a report.
        if args.contains("--print-once") {
            exit(AirDataLoader.printOnce(arguments: args))
        }
        // `AQIBar --render-icon <dir.iconset>` draws the app icon PNGs and exits.
        if let i = args.firstIndex(of: "--render-icon") {
            exit(IconRenderer.run(directory: i + 1 < args.count ? args[i + 1] : "AppIcon.iconset"))
        }
        // `AQIBar --render-preview <dir>` writes preview PNGs with sample data and exits.
        if let i = args.firstIndex(of: "--render-preview") {
            exit(PreviewRenderer.run(directory: i + 1 < args.count ? args[i + 1] : "docs"))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            Image(nsImage: MenuBarBadge.image(for: store.state))
        }
        .menuBarExtraStyle(.window)
    }
}
