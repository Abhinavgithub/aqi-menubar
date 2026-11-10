import AppKit
import SwiftUI

/// UI-only helpers for the CPCB categories.
extension AQICategory {
    var nsColor: NSColor { NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
    var color: Color { Color(nsColor: nsColor) }

    /// Yellow and light green need dark text; the other bands take white.
    var usesDarkText: Bool { self == .moderate || self == .satisfactory }
    var textNSColor: NSColor { usesDarkText ? NSColor(white: 0.1, alpha: 1) : .white }
    var textColor: Color { Color(nsColor: textNSColor) }

    /// CPCB health statements, shortened.
    var meaning: String {
        switch self {
        case .good: return "Minimal impact on health."
        case .satisfactory: return "Minor breathing discomfort for sensitive people."
        case .moderate: return "May cause breathing discomfort to people with lung or heart disease, children and older adults."
        case .poor: return "Breathing discomfort for most people on prolonged exposure."
        case .veryPoor: return "Respiratory illness for most people on prolonged exposure."
        case .severe: return "Affects healthy people and seriously impacts those with existing diseases."
        }
    }
}

/// Draws the coloured menu bar badge. Not a template image, so the colour survives.
enum MenuBarBadge {
    static let height: CGFloat = 16
    /// The badge dims once the shown data is older than this.
    static let staleAfter: TimeInterval = 3 * 3600

    static func isStale(_ s: AQISnapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(s.updated) > staleAfter
    }

    static func image(for state: AQIState) -> NSImage {
        if case let .loaded(s, _) = state {
            if isStale(s) {
                return image(text: "\(s.aqi)", fill: s.category.nsColor.withAlphaComponent(0.4),
                             textColor: s.category.textNSColor.withAlphaComponent(0.75), dashed: true)
            }
            return image(text: "\(s.aqi)", fill: s.category.nsColor, textColor: s.category.textNSColor)
        }
        return image(text: "AQI --", fill: NSColor(white: 0.55, alpha: 1), textColor: .white)
    }

    static func image(text: String, fill: NSColor, textColor: NSColor, dashed: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: max(28, ceil(textSize.width) + 12), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            fill.setFill()
            path.fill()
            // A hairline edge keeps light badges distinct on a light menu bar.
            NSColor.black.withAlphaComponent(dashed ? 0.45 : 0.18).setStroke()
            path.lineWidth = 1
            if dashed { path.setLineDash([2, 1.5], count: 2, phase: 0) }   // old data
            path.stroke()
            let origin = NSPoint(x: (rect.width - textSize.width) / 2,
                                 y: (rect.height - textSize.height) / 2 + 0.5)
            (text as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Air quality index \(text)" + (dashed ? ", data is out of date" : "")
        return image
    }
}

/// Formats the API's local "yyyy-MM-ddTHH:mm" strings using the system 12/24-hour setting.
struct HourFormatter {
    private let parser: DateFormatter
    private let hour: DateFormatter
    private let time: DateFormatter

    init(utcOffsetSeconds: Int) {
        let tz = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .current
        parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        parser.timeZone = tz
        hour = DateFormatter()
        hour.setLocalizedDateFormatFromTemplate("j")
        hour.timeZone = tz
        time = DateFormatter()
        time.timeStyle = .short
        time.timeZone = tz
    }

    func date(_ s: String) -> Date? { parser.date(from: s) }
    func hourLabel(_ s: String) -> String {
        guard let d = date(s) else { return String(s.suffix(5)) }
        // Station hours are UTC-aligned, so in UTC+5:30 they fall on :30; show the minutes then.
        return s.hasSuffix(":00") ? hour.string(from: d) : time.string(from: d)
    }
    func timeLabel(_ s: String) -> String { date(s).map(time.string(from:)) ?? String(s.suffix(5)) }
}
