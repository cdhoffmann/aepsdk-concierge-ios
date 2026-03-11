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
import AVFoundation
import Speech
import AudioToolbox
import AEPBrandConcierge

struct ContentView: View {
    private enum DemoThemeFile: String, CaseIterable, Identifiable {
        case defaultTheme = "theme-default"
        case allProperties = "theme-all-properties"
        case demoTheme = "themeDemo"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .defaultTheme:
                return "Default"
            case .allProperties:
                return "All Props"
            case .demoTheme:
                return "Demo"
            }
        }

        var chatTitle: String {
            switch self {
            case .defaultTheme, .demoTheme, .allProperties:
                return "Concierge"
            }
        }

        var chatSubtitle: String? {
            switch self {
            case .dsgTheme:
                return nil
            case .defaultTheme, .demoTheme, .allProperties:
                return "Powered by Adobe"
            }
        }
    }

    @State private var selectedThemeFile: DemoThemeFile = .dsgTheme
    @State private var loadedTheme: ConciergeTheme = ConciergeThemeLoader.default()
    @State private var themeLoadStatusText: String = ""

    var body: some View {
        TabView {

            // MARK: - manual call

            Concierge.wrap(
                VStack {
                    VStack {
                        Picker("Theme", selection: $selectedThemeFile) {
                            ForEach(DemoThemeFile.allCases) { themeFile in
                                Text(themeFile.title).tag(themeFile)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                        Text("Loaded theme: \(loadedTheme.metadata.brandName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        Text(themeLoadStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 2)

                        Button(action: {
                            // only call needed to show the concierge ui
                            Concierge.show(
                                surfaces: ["web://edge-int.adobedc.net/brand-concierge/pages/745F37C35E4B776E0A49421B@AdobeOrg/acom_m15/index.html"],
                                title: selectedThemeFile.chatTitle,
                                subtitle: selectedThemeFile.chatSubtitle
                            )
                        }) {
                            Text("Open chat (SwiftUI)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.vertical, 16)
                                .padding(.horizontal, 28)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.red)
                                        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
                                )
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                },
                hideButton: true
            )

            // Apply theme above ConciergeWrapper so the overlay (and chat view) can read it
            .conciergeTheme(loadedTheme)
            .tabItem { Label("SwiftUI", systemImage: "swift") }

            // MARK: - floating button

            Concierge.wrap(
                Label(
                    "hello, world", systemImage: "world"
                ),
                surfaces: ["web://edge-int.adobedc.net/brand-concierge/pages/745F37C35E4B776E0A49421B@AdobeOrg/acom_m15/index.html"]
            )
            .conciergeTheme(loadedTheme)
            .tabItem { Label("Magic", systemImage: "sparkles.square.filled.on.square") }

            // MARK: - Compact overlay mode

            Concierge.wrapCompact(
                VStack {
                    Text("Long press on bottom-right corner")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding()

                    Text("Hold the bottom-right corner of the screen for 0.5 seconds to activate the compact Siri-like overlay")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Spacer()

                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 80))
                        .foregroundColor(Color.Brand.red.opacity(0.3))
                        .padding(.bottom, 100)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground)),
                surfaces: ["web://edge-int.adobedc.net/brand-concierge/pages/745F37C35E4B776E0A49421B@AdobeOrg/acom_m15/index.html"]
            )
            .conciergeTheme(loadedTheme)
            .tabItem { Label("Compact", systemImage: "bubble.left.and.text.bubble.right.fill") }

            // MARK: - UIKit example

            UIKitDemoScreen()
                .tabItem { Label("UIKit", systemImage: "square.stack.3d.up.fill") }
        }
        .onAppear {
            loadTheme()
        }
        .onChange(of: selectedThemeFile) { _ in
            loadTheme()
        }
    }

    private func loadTheme() {
        let filename = selectedThemeFile.rawValue

        if let url = Bundle.main.url(forResource: filename, withExtension: "json") {
            themeLoadStatusText = "Theme file: \(url.lastPathComponent)"
        } else {
            themeLoadStatusText = "Theme file missing in main bundle: \(filename).json"
        }

        loadedTheme = ConciergeThemeLoader.load(from: filename, in: .main) ?? ConciergeThemeLoader.default()
    }
}

/// SwiftUI wrapper that hosts the UIKit demo controller inside the tab.
private struct UIKitDemoScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let root = ConciergeUIKitDemoViewController()
        let nav = UINavigationController(rootViewController: root)
        return nav
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

#Preview {
    ContentView()
}
