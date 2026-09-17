import FirebaseMessaging
import Foundation
import PromiseKit
import Shared
import SwiftUI

@MainActor
final class NotificationDebugViewModel: ObservableObject {
    // `Self` can't be referenced from a stored-property initializer in a class; use the
    // type name explicitly.
    @Published var pushIDDisplay: String = NotificationDebugViewModel
        .displayForPushID(Current.settingsStore.pushID)

    var pushID: String? { Current.settingsStore.pushID }

    private static func displayForPushID(_ id: String?) -> String {
        id ?? L10n.SettingsDetails.Notifications.PushIdSection.notRegistered
    }

    // PromiseKit also exports a single-parameter `Result`, so qualify with `Swift.Result`.
    func resetPushID(completion: @escaping (Swift.Result<Void, Error>) -> Void) {
        let messaging = Messaging.messaging()

        Current.Log.info(
            "Push reset requested: APNS token present=\(messaging.apnsToken != nil), " +
                "FCM auto-init enabled=\(messaging.isAutoInitEnabled), " +
                "stored push ID present=\(Current.settingsStore.pushID != nil)"
        )

        // On a fresh/sideloaded install Firebase may not yet have legacy check-in credentials.
        // In that state deleteToken() can fail with
        // "Failed to checkin before token registration." That must not prevent us from
        // requesting a new FCM token immediately afterwards.
        firstly {
            Promise<Void> { seal in
                messaging.deleteToken { error in
                    if let error {
                        Current.Log.warning(
                            "Push reset: deleting the existing FCM token failed; " +
                                "continuing with token registration anyway: \(error)"
                        )
                    } else {
                        Current.Log.info("Push reset: existing FCM token deleted successfully")
                    }

                    seal.fulfill(())
                }
            }
        }.then {
            Promise<String> { seal in
                Current.Log.info(
                    "Push reset: requesting new FCM token; " +
                        "APNS token present=\(messaging.apnsToken != nil)"
                )

                messaging.token { token, error in
                    if let token, !token.isEmpty {
                        Current.Log.info(
                            "Push reset: new FCM token received successfully " +
                                "(length=\(token.count))"
                        )
                        seal.fulfill(token)
                        return
                    }

                    if let error {
                        Current.Log.error("Push reset: FCM token request failed: \(error)")
                        seal.reject(error)
                        return
                    }

                    let error = NSError(
                        domain: "HomeAssistant.Push",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Firebase returned neither an FCM token nor an error.",
                        ]
                    )
                    Current.Log.error("Push reset: \(error.localizedDescription)")
                    seal.reject(error)
                }
            }
        }.done { [weak self] newToken in
            self?.pushIDDisplay = Self.displayForPushID(newToken)
        }.then { _ in
            Current.Log.info("Push reset: updating Home Assistant registration with new FCM token")
            return when(fulfilled: Current.apis.map { $0.updateRegistration() })
        }.done { _ in
            Current.Log.info("Push reset: Home Assistant registration update completed")
            completion(.success(()))
        }.catch { error in
            Current.Log.error("Error resetting push token: \(error)")
            completion(.failure(error))
        }
    }
}
