import Foundation
import ServiceManagement

/// Launch at login via SMAppService.mainApp (macOS 13+). It registers the app at its
/// current path, so it is only offered when the app runs from an Applications folder.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    init() { reload() }

    func reload() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        message = status == .requiresApproval
            ? "Approve AQI Bar in System Settings > General > Login Items." : nil
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            AppLog.write("launch at login \(on ? "enabled" : "disabled")")
        } catch {
            AppLog.write("launch at login change failed: \(error.localizedDescription)")
            message = "Couldn't change this: \(error.localizedDescription)"
        }
        let keep = message
        reload()
        if message == nil { message = keep?.hasPrefix("Couldn't") == true ? keep : nil }
    }
}
