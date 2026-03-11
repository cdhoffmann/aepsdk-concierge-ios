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

/// A UIViewRepresentable whose underlying UIView becomes first responder to receive
/// UIKit motion events (device shake). Embed in the background of any SwiftUI view.
///
/// Using UIViewRepresentable instead of UIViewControllerRepresentable avoids
/// spurious viewWillDisappear/viewDidAppear cycles that SwiftUI triggers on
/// state-heavy apps, which would cause the view controller to resign and fail
/// to re-acquire first responder.
@available(iOSApplicationExtension, unavailable)
struct ConciergeShakeDetector: UIViewRepresentable {

    let isOverlayShowing: Bool
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeView {
        ShakeView(onShake: onShake)
    }

    func updateUIView(_ uiView: ShakeView, context: Context) {
        uiView.onShake = onShake
        // Re-claim first responder after the overlay closes. A brief delay
        // lets any dismissal animation finish so the view is fully visible
        // in the hierarchy before becomeFirstResponder() is called.
        if !isOverlayShowing && !uiView.isFirstResponder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak uiView] in
                uiView?.becomeFirstResponder()
            }
        }
    }

    // MARK: - ShakeView

    final class ShakeView: UIView {
        var onShake: (() -> Void)?

        init(onShake: @escaping () -> Void) {
            self.onShake = onShake
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var canBecomeFirstResponder: Bool { true }

        /// Called whenever the view enters a window — the earliest reliable
        /// point to claim first responder without racing the layout pass.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                becomeFirstResponder()
            }
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake else { return }
            onShake?()
        }
    }
}
