import SwiftUI

/// The panel shown when the menu bar item is clicked.
struct PanelView: View {
    @ObservedObject var store: AQIStore
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        PanelContent(state: store.state, isRefreshing: store.isRefreshing, keyStatus: store.keyStatus,
                     onRefresh: { Task { await store.refresh() } },
                     onSaveKey: { store.saveKey($0) }, onRemoveKey: { store.removeKey() },
                     launchAtLogin: LaunchAtLoginState(available: LoginItem.isInstalled, isOn: loginItem.isEnabled,
                                                       message: loginItem.message),
                     onLaunchAtLogin: { loginItem.set($0) })
            .onAppear { loginItem.reload() }
    }
}

/// Stateless panel layout, so it can also be rendered with sample data (`--render-preview`).
struct PanelContent: View {
    let state: AQIState
    let isRefreshing: Bool
    var keyStatus: AQIStore.KeyStatus = .missing
    var onRefresh: () -> Void = {}
    var onSaveKey: (String) -> Void = { _ in }
    var onRemoveKey: () -> Void = {}
    var launchAtLogin = LaunchAtLoginState(available: true, isOn: false, message: nil)
    var onLaunchAtLogin: (Bool) -> Void = { _ in }

    static let width: CGFloat = 308

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .loading:
                header("Locating…")
                MessageCard(symbol: "location.magnifyingglass",
                            text: "Finding your location and loading air quality…", tint: .secondary)
            case let .needsLocationPermission(message):
                header("Location needed")
                MessageCard(symbol: "location.slash", text: message, tint: .orange) {
                    Button("Open Location Services Settings") { Self.openLocationSettings() }
                        .controlSize(.small)
                }
            case let .error(message):
                header("AQI Bar")
                MessageCard(symbol: "exclamationmark.triangle", text: message, tint: .red)
            case let .loaded(s, _):
                VStack(alignment: .leading, spacing: 3) {
                    header(s.placeName)
                    SourceLine(source: s.source, formatter: HourFormatter(utcOffsetSeconds: s.utcOffsetSeconds))
                }
                Hero(snapshot: s)
                HStack(spacing: 8) {
                    PollutantTile(name: "PM2.5", now: s.currentPM25, average: s.avgPM25,
                                  dominant: s.dominant == .pm25, subIndex: IndianAQI.pm25SubIndex)
                    PollutantTile(name: "PM10", now: s.currentPM10, average: s.avgPM10,
                                  dominant: s.dominant == .pm10, subIndex: IndianAQI.pm10SubIndex)
                }
                TrendStrip(points: s.trend, formatter: HourFormatter(utcOffsetSeconds: s.utcOffsetSeconds))
            }
            Divider()
            DataSourceSection(keyStatus: keyStatus, onSave: onSaveKey, onRemove: onRemoveKey)
            LaunchAtLoginRow(state: launchAtLogin, onChange: onLaunchAtLogin)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width)
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case let .loaded(s, nil) = state, MenuBarBadge.isStale(s) {
            Label("Data is from \(s.updated.formatted(date: .omitted, time: .shortened)), over 3 hours old",
                  systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
        }
        if case let .loaded(s, refreshError?) = state {
            Label("\(refreshError), showing data from \(s.updated.formatted(date: .omitted, time: .shortened))",
                  systemImage: refreshError == "Offline" ? "wifi.slash" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            if case let .loaded(s, _) = state {
                Text("Updated \(s.updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now (⌘R)")
            .disabled(isRefreshing)
            .keyboardShortcut("r")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
        Text(attribution)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var attribution: String {
        if case let .loaded(s, _) = state, case .station = s.source {
            return "Data: OpenAQ stations. AQI: CPCB scale, live hourly."
        }
        return "Data: Open-Meteo model. AQI: CPCB scale, live hourly."
    }

    static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct Hero: View {
    let snapshot: AQISnapshot

    var body: some View {
        let c = snapshot.category
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                Text("\(snapshot.aqi)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("LIVE AQI")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(c.textColor)
            .frame(width: 84, height: 64)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.color))
            .help("Live AQI from the latest hourly PM2.5 and PM10 readings")

            VStack(alignment: .leading, spacing: 3) {
                Text(c.name)
                    .font(.title3.weight(.semibold))
                Text(c.meaning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let avg = snapshot.averageAQI {
                    Text("24h average AQI \(avg) · \(AQICategory(aqi: avg).name)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("CPCB's official AQI uses 24-hour averages")
                }
            }
        }
    }
}

private struct PollutantTile: View {
    let name: String
    let now: Double?
    let average: Double?
    let dominant: Bool
    let subIndex: (Double) -> Double

    /// The CPCB band this pollutant's own live concentration falls in.
    private var category: AQICategory? {
        now.map { AQICategory(aqi: Int(subIndex($0).rounded())) }
    }

    var body: some View {
        let c = category
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if dominant {
                    Text("MAIN")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .foregroundStyle(.secondary)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 0.8))
                        .help("This pollutant sets the AQI")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(fmt(now)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("µg/m³").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                if let c {
                    Text(c.name)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .foregroundStyle(c.textColor)
                        .background(Capsule().fill(c.color))
                        .help("\(name) on its own is \(c.name) (CPCB sub-index \(Int(subIndex(now!).rounded())))")
                }
                Spacer(minLength: 2)
                Text("24h \(fmt(average))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("24-hour average, µg/m³")
            }
        }
        .padding(.leading, 13).padding(.trailing, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(c?.color.opacity(0.14) ?? Color.primary.opacity(0.06)))
        // Colour bar on the leading edge, in the pollutant's band colour.
        .overlay(alignment: .leading) {
            if let c {
                RoundedRectangle(cornerRadius: 1.5).fill(c.color).frame(width: 3).padding(.vertical, 8).padding(.leading, 4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder((c?.color ?? .primary).opacity(dominant ? 0.6 : 0.0), lineWidth: 1))
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "--" }
}

private struct TrendStrip: View {
    let points: [TrendPoint]
    let formatter: HourFormatter

    static let cell: CGFloat = 21
    static let spacing: CGFloat = 2.3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 12 hours").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: Self.spacing) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    cell(p)
                }
            }
            HStack(spacing: Self.spacing) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    // Label the newest hour and every 3rd hour back from it.
                    let show = (points.count - 1 - i) % 3 == 0
                    Text(show ? formatter.hourLabel(p.time) : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: Self.cell)
                }
            }
        }
    }

    private func cell(_ p: TrendPoint) -> some View {
        let category = p.aqi.map(AQICategory.init(aqi:))
        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(category?.color ?? Color.primary.opacity(0.1))
            Text(p.aqi.map(String.init) ?? "–")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .foregroundStyle(category?.textColor ?? .secondary)
        }
        .frame(width: Self.cell, height: 24)
        .help(tooltip(p))
    }

    private func tooltip(_ p: TrendPoint) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "--" }
        let aqi = p.aqi.map { "AQI \($0) (\(AQICategory(aqi: $0).name))" } ?? "AQI -- (not enough data)"
        return "\(formatter.timeLabel(p.time))\n\(aqi)\nPM2.5 \(f(p.pm25)) µg/m³\nPM10 \(f(p.pm10)) µg/m³"
    }
}

private struct MessageCard<Actions: View>: View {
    let symbol: String
    let text: String
    let tint: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

extension MessageCard where Actions == EmptyView {
    init(symbol: String, text: String, tint: Color) {
        self.init(symbol: symbol, text: text, tint: tint) { EmptyView() }
    }
}

/// Says plainly where the numbers come from, and how old the station reading is.
private struct SourceLine: View {
    let source: DataSource
    let formatter: HourFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch source {
            case let .station(pm25, pm10):
                if let a = pm25, let b = pm10, a.choice.locationId != b.choice.locationId {
                    line("antenna.radiowaves.left.and.right", "PM2.5: \(describe(a))")
                    line("antenna.radiowaves.left.and.right", "PM10: \(describe(b))")
                } else if let r = pm25 ?? pm10 {
                    line("antenna.radiowaves.left.and.right", "Station: \(describe(r))")
                    if pm25 == nil { line("exclamationmark.circle", "This station has no PM2.5 sensor") }
                    if pm10 == nil { line("exclamationmark.circle", "This station has no PM10 sensor") }
                }
            case let .model(reason):
                line("cloud", "Model estimate (Open-Meteo): \(reason)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func describe(_ r: StationReading) -> String {
        "\(r.choice.name), \(String(format: "%.1f", r.choice.distanceKm)) km away, reading from \(r.time.formatted(date: .omitted, time: .shortened))"
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9)).frame(width: 12)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// OpenAQ key entry: paste, Save, Remove, and a link to get a free key.
private struct DataSourceSection: View {
    let keyStatus: AQIStore.KeyStatus
    let onSave: (String) -> Void
    let onRemove: () -> Void
    // Plain ObservableObject: @State is a macro in this SDK and needs Xcode's plugin.
    @StateObject private var form = KeyForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Data source").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                status
            }
            if keyStatus == .missing || keyStatus == .rejected || form.editing {
                HStack(spacing: 6) {
                    SecureField("Paste OpenAQ API key", text: $form.draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(form.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
                HStack(spacing: 4) {
                    Text("Ground-station readings need a free key.")
                    Link("Get one", destination: URL(string: "https://explore.openaq.org/register")!)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if keyStatus != .missing && !form.editing {
                HStack(spacing: 8) {
                    Button("Replace key") { form.editing = true }
                    Button("Remove key", role: .destructive, action: onRemove)
                }
                .controlSize(.small)
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch keyStatus {
        case .missing:
            Text("No OpenAQ key").font(.caption2).foregroundStyle(.secondary)
        case .saved:
            Label("OpenAQ key saved", systemImage: "key.fill").font(.caption2).foregroundStyle(.secondary)
        case .working:
            Label("OpenAQ key working", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .rejected:
            Label("Key not accepted", systemImage: "xmark.octagon.fill").font(.caption2).foregroundStyle(.red)
        }
    }

    private func save() {
        let key = form.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        onSave(key)
        form.draft = ""
        form.editing = false
    }
}

private final class KeyForm: ObservableObject {
    @Published var draft = ""
    @Published var editing = false
}

struct LaunchAtLoginState {
    let available: Bool
    let isOn: Bool
    let message: String?
}

private struct LaunchAtLoginRow: View {
    let state: LaunchAtLoginState
    let onChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { state.isOn }, set: onChange)) {
                Text("Open at login").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!state.available)
            if !state.available {
                Text("Install AQI Bar with ./install.sh to turn this on.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let m = state.message {
                Text(m).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
