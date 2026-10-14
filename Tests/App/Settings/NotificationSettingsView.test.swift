@testable import HomeAssistant
@testable import Shared
import SwiftUI
import Testing

// Serialized: the tests swap `Current.isCatalyst`, which concurrent tests would race on.
@Suite(.serialized)
struct NotificationSettingsViewTests {
    @MainActor
    @Test func buildsContentAndIndexesForceCloseWarningRowOnIOS() {
        withCatalyst(false) {
            // Exercise the view builder without presenting a real window or triggering onAppear.
            _ = NotificationSettingsView().body
            let titles = NotificationSettingsView.settingsSearchEntries.map(\.title)
            #expect(titles.contains(L10n.SettingsDetails.Notifications.ForceCloseWarning.title))
        }
    }

    @MainActor
    @Test func buildsContentWithoutForceCloseWarningRowOnCatalyst() {
        withCatalyst(true) {
            _ = NotificationSettingsView().body
            let titles = NotificationSettingsView.settingsSearchEntries.map(\.title)
            #expect(!titles.contains(L10n.SettingsDetails.Notifications.ForceCloseWarning.title))
        }
    }

    @Test func settingsSearchIndexesForceCloseWarningRow() {
        withCatalyst(false) {
            let titles = NotificationSettingsView.settingsSearchEntries.map(\.title)
            #expect(titles.contains(L10n.SettingsDetails.Notifications.ForceCloseWarning.title))
        }
    }

    @Test func settingsSearchSkipsForceCloseWarningRowOnCatalyst() {
        withCatalyst(true) {
            let titles = NotificationSettingsView.settingsSearchEntries.map(\.title)
            #expect(!titles.contains(L10n.SettingsDetails.Notifications.ForceCloseWarning.title))
            #expect(titles.contains(L10n.SettingsDetails.Notifications.Sounds.title))
        }
    }

    private func withCatalyst(_ isCatalyst: Bool, _ body: () throws -> Void) rethrows {
        let previous = Current.isCatalyst
        Current.isCatalyst = isCatalyst
        defer { Current.isCatalyst = previous }
        try body()
    }
}
