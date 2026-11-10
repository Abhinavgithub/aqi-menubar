import AppKit
import SwiftUI

/// `AQIBar --render-preview <dir>` writes PNGs of the panel and the badges using sample data.
@MainActor
enum PreviewRenderer {
    static func run(directory: String) -> Int32 {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sample = sampleSnapshot()
        let states: [(String, AQIState)] = [
            ("panel", .loaded(sample, refreshError: nil)),
            ("panel-model", .loaded(AQISnapshot(placeName: sample.placeName, aqi: sample.aqi, category: sample.category,
                                                dominant: sample.dominant, currentPM25: sample.currentPM25,
                                                currentPM10: sample.currentPM10, avgPM25: sample.avgPM25,
                                                avgPM10: sample.avgPM10, averageAQI: sample.averageAQI,
                                                trend: sample.trend, dataTime: sample.dataTime,
                                                utcOffsetSeconds: sample.utcOffsetSeconds,
                                                source: .model(reason: "no OpenAQ key"), updated: sample.updated),
                                    refreshError: nil)),
            ("panel-offline", .loaded(AQISnapshot(placeName: sample.placeName, aqi: sample.aqi, category: sample.category,
                                                  dominant: sample.dominant, currentPM25: sample.currentPM25,
                                                  currentPM10: sample.currentPM10, avgPM25: sample.avgPM25,
                                                  avgPM10: sample.avgPM10, averageAQI: sample.averageAQI,
                                                  trend: sample.trend, dataTime: sample.dataTime,
                                                  utcOffsetSeconds: sample.utcOffsetSeconds, source: sample.source,
                                                  updated: Date().addingTimeInterval(-4 * 3600)),
                                      refreshError: "Offline")),
            ("panel-permission", .needsLocationPermission("Location access is off for AQI Bar. Turn it on in System Settings > Privacy & Security > Location Services.")),
        ]
        var ok = true
        for (name, state) in states {
            for dark in [false, true] {
                let keyStatus: AQIStore.KeyStatus = name == "panel" || name == "panel-offline" ? .working : .missing
                let view = PanelContent(state: state, isRefreshing: false, keyStatus: keyStatus,
                                        launchAtLogin: LaunchAtLoginState(available: name != "panel-model", isOn: false,
                                                                          message: nil))
                    .background(Color(nsColor: .windowBackgroundColor))
                let path = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                ok = write(view: view, dark: dark, to: path) && ok
            }
        }
        ok = writeBadges(to: dir.appendingPathComponent("badges.png")) && ok
        print(ok ? "Wrote previews to \(dir.path)" : "Some previews failed")
        return ok ? 0 : 1
    }

    static func sampleSnapshot() -> AQISnapshot {
        let aqis: [Int?] = [70, 63, 57, 52, 49, 57, 74, 93, 130, nil, 196, 212]
        let trend = aqis.enumerated().map { i, a in
            TrendPoint(time: String(format: "2026-11-10T%02d:00", 11 + i), aqi: a,
                       pm25: a.map { Double($0) * 0.5 }, pm10: a.map { Double($0) * 0.6 })
        }
        return AQISnapshot(placeName: "Sample Park, Sample City", aqi: 212, category: .poor,
                           dominant: .pm25, currentPM25: 94.1, currentPM10: 97.8, avgPM25: 83.1,
                           avgPM10: 89.8, averageAQI: 177, trend: trend, dataTime: "2026-11-10T22:30",
                           utcOffsetSeconds: 19800,
                           source: .station(pm25: sampleReading(94.1), pm10: sampleReading(97.8)), updated: Date())
    }

    static func sampleReading(_ v: Double) -> StationReading {
        StationReading(choice: StationChoice(locationId: 1, sensorId: 2, name: "City Centre Monitoring Station",
                                             distanceKm: 3.4),
                       value: v, time: Date().addingTimeInterval(-40 * 60))
    }

    private static func write<V: View>(view: V, dark: Bool, to url: URL) -> Bool {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return save(rep, to: url)
    }

    /// Every category's badge plus the neutral one, on a light and a dark menu bar, at 2x.
    private static func writeBadges(to url: URL) -> Bool {
        var badges: [NSImage] = [MenuBarBadge.image(for: .loading)]
        for (c, n) in zip(AQICategory.allCases, [42, 88, 177, 245, 356, 452]) {
            badges.append(MenuBarBadge.image(text: "\(n)", fill: c.nsColor, textColor: c.textNSColor))
        }
        // Out-of-date data (older than 3 hours): dimmed, dashed edge.
        badges.append(MenuBarBadge.image(text: "212", fill: AQICategory.poor.nsColor.withAlphaComponent(0.4),
                                         textColor: AQICategory.poor.textNSColor.withAlphaComponent(0.75), dashed: true))
        let gap: CGFloat = 10, barH: CGFloat = 24, scale: CGFloat = 2
        let width = badges.reduce(gap) { $0 + $1.size.width + gap }
        let size = NSSize(width: width, height: barH * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, bg) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.16, alpha: 1)].enumerated() {
            bg.setFill()
            let y = CGFloat(1 - row) * barH
            NSRect(x: 0, y: y, width: width, height: barH).fill()
            var x = gap
            for b in badges {
                b.draw(in: NSRect(x: x, y: y + (barH - b.size.height) / 2, width: b.size.width, height: b.size.height))
                x += b.size.width + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return save(rep, to: url)
    }

    private static func save(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
