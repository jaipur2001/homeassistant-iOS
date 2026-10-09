import Shared
import UIKit
@preconcurrency import WebKit

// MARK: - Web View Configuration & Setup

extension WebViewController {
    func setupUserContentController() -> WKUserContentController {
        let userContentController = WKUserContentController()
        let safeScriptMessageHandler = SafeScriptMessageHandler(server: server, delegate: webViewScriptMessageHandler)
        userContentController.add(safeScriptMessageHandler, name: "getExternalAuth")
        userContentController.add(safeScriptMessageHandler, name: "revokeExternalAuth")
        userContentController.add(safeScriptMessageHandler, name: "externalBus")
        userContentController.add(safeScriptMessageHandler, name: "updateThemeColors")
        userContentController.add(safeScriptMessageHandler, name: "logError")
        userContentController.add(safeScriptMessageHandler, name: "frontendRestored")

        // Route clipboard writes through the native bridge so iframe calls update the pasteboard reliably.
        // Install it in every frame so ingress panels use the same path and receive the native result.
        userContentController.addScriptMessageHandler(
            ClipboardWriteMessageHandler(server: server),
            contentWorld: .page,
            name: ClipboardWriteMessageHandler.messageName
        )
        userContentController.addUserScript(ClipboardWriteMessageHandler.userScript)

        // Managed kiosk frontend policy.
        //
        // The Home Assistant user item is rendered by <ha-sidebar> as
        // #sidebar-profile with href="/profile". Profile navigation is client-side
        // (History API), so WKNavigationDelegate alone cannot reliably block it.
        //
        // Install a document-start policy that:
        // - blocks the hass-logout event;
        // - disables the sidebar profile item visually and functionally;
        // - blocks click/keyboard activation of /profile;
        // - blocks SPA navigation to protected HA routes through history.pushState/
        //   replaceState.
        //
        // Native revokeExternalAuth protection remains the final token-revocation
        // backstop even if the frontend implementation changes.
        let managedKioskEnabled = Current.kioskSettings.enabled ? "true" : "false"
        let managedKioskPolicySource = """
        (function() {
            window.__haManagedKioskPolicyEnabled = \(managedKioskEnabled);
            window.__haManagedKioskLogoutBlocked = \(managedKioskEnabled);

            if (window.__haManagedKioskPolicyInstalled === true) {
                if (typeof window.__haManagedKioskApplyProfileLock === 'function') {
                    window.__haManagedKioskApplyProfileLock();
                }
                return;
            }

            window.__haManagedKioskPolicyInstalled = true;

            const restrictedPrefixes = [
                '/profile',
                '/config',
                '/developer-tools'
            ];

            const isRestrictedPath = function(value) {
                try {
                    const url = new URL(value || window.location.href, window.location.href);
                    return restrictedPrefixes.some(function(prefix) {
                        return url.pathname === prefix || url.pathname.startsWith(prefix + '/');
                    });
                } catch (_) {
                    return false;
                }
            };

            const profileTargetInEvent = function(event) {
                const path = typeof event.composedPath === 'function'
                    ? event.composedPath()
                    : [];

                return path.some(function(node) {
                    if (!(node instanceof Element)) {
                        return false;
                    }

                    if (node.id === 'sidebar-profile') {
                        return true;
                    }

                    const href = node.getAttribute && node.getAttribute('href');
                    if (!href) {
                        return false;
                    }

                    try {
                        const url = new URL(href, window.location.href);
                        return url.pathname === '/profile' || url.pathname.startsWith('/profile/');
                    } catch (_) {
                        return false;
                    }
                });
            };

            const observedRoots = new WeakSet();

            const applyProfileLock = function(root) {
                if (!root || typeof root.querySelectorAll !== 'function') {
                    return;
                }

                const enabled = window.__haManagedKioskPolicyEnabled === true;
                const profileItems = root.querySelectorAll('#sidebar-profile');

                profileItems.forEach(function(item) {
                    if (enabled) {
                        item.setAttribute('aria-disabled', 'true');
                        item.setAttribute('data-managed-kiosk-locked', 'true');
                        item.style.pointerEvents = 'none';
                        item.style.opacity = '0.45';
                        item.title = 'Im Kiosk-Modus gesperrt';
                    } else if (item.getAttribute('data-managed-kiosk-locked') === 'true') {
                        item.removeAttribute('aria-disabled');
                        item.removeAttribute('data-managed-kiosk-locked');
                        item.style.removeProperty('pointer-events');
                        item.style.removeProperty('opacity');
                        if (item.title === 'Im Kiosk-Modus gesperrt') {
                            item.removeAttribute('title');
                        }
                    }
                });

                root.querySelectorAll('*').forEach(function(element) {
                    if (element.shadowRoot) {
                        observeRoot(element.shadowRoot);
                    }
                });
            };

            const observeRoot = function(root) {
                if (!root || observedRoots.has(root)) {
                    return;
                }

                observedRoots.add(root);

                const observer = new MutationObserver(function() {
                    applyProfileLock(root);
                });

                observer.observe(root, {
                    childList: true,
                    subtree: true
                });

                applyProfileLock(root);
            };

            window.__haManagedKioskApplyProfileLock = function() {
                applyProfileLock(document);
            };

            window.addEventListener('hass-logout', function(event) {
                if (window.__haManagedKioskLogoutBlocked !== true) {
                    return;
                }

                event.preventDefault();
                event.stopImmediatePropagation();
                console.warn('Managed kiosk policy: Home Assistant logout blocked');
            }, true);

            window.addEventListener('click', function(event) {
                if (window.__haManagedKioskPolicyEnabled !== true) {
                    return;
                }

                if (!profileTargetInEvent(event)) {
                    return;
                }

                event.preventDefault();
                event.stopImmediatePropagation();
                console.warn('Managed kiosk policy: user profile activation blocked');
            }, true);

            const originalPushState = history.pushState;
            history.pushState = function(state, title, url) {
                if (window.__haManagedKioskPolicyEnabled === true &&
                    url != null &&
                    isRestrictedPath(url)) {
                    console.warn('Managed kiosk policy: blocked SPA navigation to ' + url);
                    return;
                }

                return originalPushState.apply(this, arguments);
            };

            const originalReplaceState = history.replaceState;
            history.replaceState = function(state, title, url) {
                if (window.__haManagedKioskPolicyEnabled === true &&
                    url != null &&
                    isRestrictedPath(url)) {
                    console.warn('Managed kiosk policy: blocked SPA navigation to ' + url);
                    return;
                }

                return originalReplaceState.apply(this, arguments);
            };

            observeRoot(document);

            if (document.documentElement) {
                applyProfileLock(document);
            } else {
                document.addEventListener('DOMContentLoaded', function() {
                    applyProfileLock(document);
                }, { once: true });
            }
        })();
        """

        userContentController.addUserScript(WKUserScript(
            source: managedKioskPolicySource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        return userContentController
    }

    func setupWebViewConstraints(statusBarView: UIView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        webView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true
        webView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if Current.isCatalyst {
            // Catalyst always shows the native status-bar buttons; pin the web view below them.
            webViewTopConstraint = webView.topAnchor.constraint(equalTo: statusBarView.bottomAnchor)
        } else {
            // iOS: the web view is edge-to-edge apart from the offset `updateWindowControlsInset()` gives it.
            // `HomeAssistantView` (SwiftUI) draws the themed status-bar bar and honours the edge-to-edge
            // setting; the web content insets itself via CSS.
            statusBarView.isHidden = true
            statusBarBottomConstraint?.isActive = false
            statusBarBottomConstraint = statusBarView.bottomAnchor.constraint(equalTo: webView.topAnchor)
            statusBarBottomConstraint?.isActive = true
            webViewTopConstraint = webView.topAnchor.constraint(equalTo: view.topAnchor)
        }
        webViewTopConstraint?.isActive = true
        updateWindowControlsInset()
    }

    func setupURLObserver() {
        urlObserver = webView.observe(\.url) { [weak self] webView, _ in
            guard let self else { return }

            guard let currentURL = webView.url?.absoluteString.replacingOccurrences(of: "?external_auth=1", with: ""),
                  let cleanURL = URL(string: currentURL), let scheme = cleanURL.scheme else {
                return
            }

            guard ["http", "https"].contains(scheme) else {
                Current.Log.warning("Was going to provide invalid URL to NSUserActivity! \(currentURL)")
                return
            }

            userActivity?.webpageURL = cleanURL
            userActivity?.userInfo = [
                RestorableStateKey.lastURL.rawValue: cleanURL,
                RestorableStateKey.server.rawValue: server.identifier.rawValue,
            ]
            userActivity?.becomeCurrent()

            // The page moved, so what the system reads off this activity has to follow it.
            updateOnscreenContent()

            // Persist the server and a host-agnostic path so cold launch reopens here; the base URL is
            // re-resolved from current connectivity at load time (see `resolvedLoadURL`).
            Current.settingsStore.lastActiveServerIdentifier = server.identifier.rawValue
            if let components = URLComponents(url: cleanURL, resolvingAgainstBaseURL: false) {
                let path = components.path.isEmpty ? "/" : components.path
                Task { @MainActor [weak overlayState] in
                    overlayState?.currentPath = path
                }
                var relative = path
                if let query = components.query {
                    relative += "?\(query)"
                }
                if let fragment = components.fragment {
                    relative += "#\(fragment)"
                }
                Current.settingsStore.lastActiveURLPath = relative
            }
        }
    }
}
