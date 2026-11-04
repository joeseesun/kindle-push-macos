import AppKit
import Sparkle

/// Sparkle auto-update. Feed: `appcast.xml` attached to the latest GitHub release (script/package_release.sh),
/// signed with the EdDSA key whose public half is `SUPublicEDKey` in Info.plist.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
