/*
 Copyright 2025 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import SwiftUI
import UIKit

// MARK: - CompactOverlayWindowHost

/// Manages a dedicated UIWindow for the compact overlay so it renders above all
/// app content, including SwiftUI sheets and other presented view controllers.
@available(iOSApplicationExtension, unavailable)
@MainActor
private final class CompactOverlayWindowHost: ObservableObject {
    private var overlayWindow: UIWindow?

    /// Creates and shows the overlay window hosting the given view.
    /// The window sits at `.alert + 1` so it appears above every sheet presentation.
    func show(_ view: some View, in windowScene: UIWindowScene) {
        guard overlayWindow == nil else { return }
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isOpaque = false
        let hostingController = UIHostingController(rootView: AnyView(view))
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.isHidden = false
        overlayWindow = window
    }

    /// Hides and releases the overlay window.
    func hide() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }
}

// MARK: - ConciergeCompactWrapper

/// Container that overlays the Concierge compact UI on top of app content.
/// Shake the device to trigger the compact overlay from any screen.
@available(iOSApplicationExtension, unavailable)
struct ConciergeCompactWrapper<Content: View>: View {
    let content: Content
    @StateObject private var stateManager = ConciergeOverlayManager.shared
    @StateObject private var windowHost = CompactOverlayWindowHost()
    @Environment(\.conciergeTheme) private var theme

    init(content: Content) {
        self.content = content
    }

    var body: some View {
        content
            .background(
                ConciergeShakeDetector(isOverlayShowing: stateManager.showingCompactOverlay) {
                    guard !stateManager.showingCompactOverlay else { return }
                    showCompactConcierge()
                }
            )
            .onChange(of: stateManager.showingCompactOverlay) { isShowing in
                if isShowing,
                   let compactView = stateManager.compactView,
                   let windowScene = UIApplication.shared.connectedScenes
                       .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                    windowHost.show(compactView.conciergeTheme(theme), in: windowScene)
                } else {
                    windowHost.hide()
                }
            }
    }

    // MARK: - Show

    private func showCompactConcierge() {
        Task { @MainActor in
            var snapshot: UIImage?
            if let windowScene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                snapshot = renderer.image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
            }
            let additionalContext = Concierge.additionalContextProvider?()
            Concierge.showCompact(surfaces: Concierge.surfaces, screenSnapshot: snapshot, additionalContext: additionalContext)
        }
    }
}
