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
import AEPCore
import AEPServices

/// Minimal Siri-like overlay showing only messages and input bar on translucent backdrop.
public struct CompactOverlayView: View {
    private let LOG_TAG = "CompactOverlayView"

    // MARK: - Environment

    @Environment(\.conciergeTheme) private var theme

    // MARK: - State

    @StateObject private var controller: ChatController
    @ObservedObject private var inputController: InputController
    @State private var selectedTextRange: NSRange = NSRange(location: 0, length: 0)
    @State private var composerHeight: CGFloat = 0
    @State private var isInputFocused: Bool = false
    /// Background task resolving the on-device LLM context summary (screen OCR).
    @State private var contextTask: Task<String?, Never>? = nil
    /// Resolved context summary shown as a bubble above the input bar.
    @State private var availableContext: String? = nil
    /// Background task resolving the on-device LLM action log insight.
    @State private var intelligenceTask: Task<String?, Never>? = nil
    /// Resolved action log insight shown as an intelligence bubble above the context bubble.
    @State private var intelligenceSummary: String? = nil
    /// Prevents duplicate sends during the brief await window before context resolves.
    @State private var isSending = false
    /// Drives the slide-up + fade-in entrance animation.
    @State private var isVisible = false

    // MARK: - Dependencies and Configuration

    private let textSpeaker: TextSpeaking?
    private let onDismiss: (() -> Void)?
    private var conciergeConfiguration: ConciergeConfiguration
    private let screenSnapshot: UIImage?
    private let additionalContext: String?

    // MARK: - UI

    private let hapticFeedback = UIImpactFeedbackGenerator(style: .heavy)

    // MARK: - Initializers

    public init(
        speechCapturer: SpeechCapturing? = nil,
        textSpeaker: TextSpeaking? = nil,
        conciergeConfiguration: ConciergeConfiguration,
        screenSnapshot: UIImage? = nil,
        additionalContext: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.textSpeaker = textSpeaker
        self.onDismiss = onDismiss
        self.conciergeConfiguration = conciergeConfiguration
        self.screenSnapshot = screenSnapshot
        self.additionalContext = additionalContext

        let chatController = ChatController(
            configuration: conciergeConfiguration,
            speechCapturer: speechCapturer ?? SpeechCapturer(),
            speaker: textSpeaker
        )
        _controller = StateObject(wrappedValue: chatController)
        _inputController = ObservedObject(wrappedValue: chatController.inputController)
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Semi-transparent backdrop - tap to dismiss
                Color.black.opacity(isVisible ? 0.75 : 0)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissOverlay()
                    }

                VStack(spacing: 0) {
                    Spacer()

                    let messageAreaHeight = geometry.size.height * 0.65

                    VStack(spacing: 0) {
                        // Messages directly on translucent backdrop, edge-to-edge
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 12) {
                                    ForEach(filterMessages()) { message in
                                        ChatMessageView(
                                            messageId: message.id,
                                            template: message.template,
                                            messageBody: message.messageBody,
                                            sources: message.sources,
                                            promptSuggestions: message.promptSuggestions,
                                            feedbackSentiment: message.feedbackSentiment,
                                            onSuggestionTap: { suggestion in
                                                isInputFocused = true
                                                controller.applyTextChange(suggestion)
                                                selectedTextRange = NSRange(location: suggestion.utf16.count, length: 0)
                                            }
                                        )
                                        .id(message.id)
                                        .onAppear {
                                            if message.shouldSpeakMessage, let messageBody = message.messageBody {
                                                textSpeaker?.utter(text: messageBody)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 8) // Edge-to-edge with minimal padding
                                .padding(.vertical, 16)
                            }
                            .frame(height: messageAreaHeight - composerHeight - 20)
                            .onChange(of: controller.userScrollTick) { _ in
                                guard let messageId = controller.userMessageToScrollId else { return }
                                withAnimation {
                                    proxy.scrollTo(messageId, anchor: .bottom)
                                }
                            }
                        }

                        // Intelligence bubble — action log insight, shown above context bubble, never sent to chat
                        if let summary = intelligenceSummary {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.top, 1)
                                Text(summary)
                                    .font(.system(size: 14, weight: .regular))
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundColor(theme.colors.message.conciergeText.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: theme.layout.messageBorderRadius, style: .continuous)
                                    .fill(theme.colors.message.conciergeBackground.color.opacity(0.7))
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // Context bubble — appears when on-device context summary is ready
                        if let context = availableContext {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.top, 1)
                                Text(context)
                                    .font(.system(size: 14, weight: .regular))
                                    .lineLimit(4)
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundColor(theme.colors.message.conciergeText.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: theme.layout.messageBorderRadius, style: .continuous)
                                    .fill(theme.colors.message.conciergeBackground.color)
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // Minimal translucent input bar at bottom
                        CompactInputBar(
                            inputText: Binding(
                                get: { inputController.data.text },
                                set: { controller.applyTextChange($0) }
                            ),
                            selectedRange: $selectedTextRange,
                            measuredHeight: $composerHeight,
                            isFocused: $isInputFocused,
                            inputState: inputController.state,
                            chatState: controller.chatState,
                            composerEditable: controller.chatState != .processing,
                            micEnabled: controller.micEnabled && theme.behavior.input.enableVoiceInput,
                            sendEnabled: inputController.data.canSend && !isSending,
                            onMicTap: handleMicTap,
                            onComplete: {
                                controller.completeMic()
                                hapticFeedback.impactOccurred()
                            },
                            onSend: sendTapped
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    .padding(.bottom, 20)
                    .opacity(isVisible ? 1 : 0)
                    .offset(y: isVisible ? 0 : 60)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .onAppear {
                hapticFeedback.prepare()
                isInputFocused = true
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    isVisible = true
                }
                Task { await controller.loadWelcomeIfNeeded(theme: theme) }
                // Kick off context processing in the background. The result is
                // prepended to the user's message at send time and shown as a bubble above the input.
                contextTask = Task {
                    let result = await IntelligentContextEngineService.processContext(
                        brandName: theme.metadata.brandName,
                        screenSnapshot: screenSnapshot
                    )
                    await MainActor.run {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            availableContext = result
                        }
                    }
                    return result
                }
                // Kick off the action log intelligence summary in parallel.
                // Shown as a separate bubble above the context bubble — never sent to the chat service.
                if let actions = additionalContext, !actions.isEmpty {
                    intelligenceTask = Task {
                        let result = await IntelligentContextEngineService.processActionLog(
                            recentActions: actions,
                            brandName: theme.metadata.brandName
                        )
                        await MainActor.run {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                intelligenceSummary = result
                            }
                        }
                        return result
                    }
                }
            }
        }
        .conciergePlaceholderConfig(
            ConciergeResponsePlaceholderConfig(
                loadingText: theme.text.loadingMessage,
                primaryDotColor: theme.colors.primary.primary.color
            )
        )
        // Enable feedback presentation
        .conciergeFeedbackPresenter(ConciergeFeedbackPresenter { sentiment, messageId in
            // For compact mode, we could either show minimal feedback or expand to full chat
            expandToFullChat()
        })
        // Enable webview presentation
        .conciergeWebViewPresenter(ConciergeWebViewPresenter { url in
            // For compact mode, open links by expanding to full chat
            expandToFullChat()
        })
    }

    // MARK: - Helpers

    /// Filter messages to show in compact view - only the latest question and response
    private func filterMessages() -> [Message] {
        let relevant = controller.messages.filter { message in
            switch message.template {
            case .basic:
                return true
            default:
                return false
            }
        }

        // Find the last user message and everything after it (the latest response)
        guard let lastUserIndex = relevant.indices.last(where: {
            if case .basic(let isUser) = relevant[$0].template { return isUser }
            return false
        }) else {
            return Array(relevant.suffix(1))
        }

        return Array(relevant[lastUserIndex...])
    }

    // MARK: - Actions

    private func sendTapped() {
        guard !isSending else { return }
        let userText = inputController.data.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        isSending = true
        hapticFeedback.impactOccurred(intensity: 0.5)
        hapticFeedback.impactOccurred(intensity: 0.7)

        Task { @MainActor in
            defer { isSending = false }
            // Wait for the context task if it is still running.
            let context = await contextTask?.value

            // Build the text to send: prepend context summary if available.
            let parts = [context, userText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let textToSend = parts.joined(separator: "\n")

            // Dismiss both bubbles before sending.
            withAnimation(.easeIn(duration: 0.15)) {
                availableContext = nil
                intelligenceSummary = nil
            }

            controller.applyTextChange(textToSend)
            controller.sendMessage(isUser: true)
        }
    }

    private func handleMicTap() {
        if controller.isRecording {
            controller.toggleMic(currentSelectionLocation: selectedTextRange.location)
        } else {
            hapticFeedback.impactOccurred()
            controller.toggleMic(currentSelectionLocation: selectedTextRange.location)
        }
    }

    private func dismissOverlay() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            Concierge.hideCompact()
        }
    }

    private func expandToFullChat() {
        dismissOverlay()
        // Show the full chat with the same configuration
        Concierge.show(surfaces: conciergeConfiguration.surfaces)
    }
}

// MARK: - Compact Input Bar

/// Minimal input bar for compact overlay - just the essential controls with translucent background
private struct CompactInputBar: View {
    @Environment(\.conciergeTheme) private var theme
    @State private var glowRotation: Double = 0

    @Binding var inputText: String
    @Binding var selectedRange: NSRange
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let inputState: InputState
    let chatState: ChatState
    let composerEditable: Bool
    let micEnabled: Bool
    let sendEnabled: Bool
    let onMicTap: () -> Void
    let onComplete: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Stop button when recording
            if case .recording = inputState {
                Button(action: onComplete) {
                    ZStack {
                        Circle()
                            .fill(theme.colors.primary.text.color)
                            .frame(width: 28, height: 28)
                        BrandIcon(assetName: "S2_Icon_Stop_20_N", systemName: "stop.fill")
                            .foregroundColor(theme.colors.primary.primary.color)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .buttonStyle(.plain)
            }

            // The actual input field with mic and send buttons
            ComposerEditingView(
                inputText: $inputText,
                selectedRange: $selectedRange,
                measuredHeight: $measuredHeight,
                isFocused: $isFocused,
                isEditable: composerEditable,
                showMic: theme.behavior.input.enableVoiceInput && !(inputState == .recording),
                onEditingChanged: { _ in },
                onMicTap: onMicTap,
                micEnabled: micEnabled,
                sendEnabled: sendEnabled,
                onSend: onSend
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: theme.layout.inputBorderRadius, style: .continuous)
                    .fill(theme.components.inputBar.background.color)
            )
            .overlay(
                ZStack {
                    // Base border
                    RoundedRectangle(cornerRadius: theme.layout.inputBorderRadius, style: .continuous)
                        .stroke(theme.components.inputBar.border.color.color, lineWidth: theme.components.inputBar.border.width)
                    // Focus outline
                    if isFocused {
                        RoundedRectangle(cornerRadius: theme.layout.inputBorderRadius, style: .continuous)
                            .stroke(theme.colors.input.outlineFocus.color, lineWidth: theme.layout.inputFocusOutlineWidth)
                    }
                    // Recording glow border
                    if case .recording = inputState {
                        RoundedRectangle(cornerRadius: theme.layout.inputBorderRadius, style: .continuous)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        theme.colors.primary.primary.color.opacity(0),
                                        theme.colors.primary.primary.color,
                                        theme.colors.primary.primary.color.opacity(0)
                                    ]),
                                    center: .center,
                                    angle: .degrees(glowRotation)
                                ),
                                lineWidth: 2
                            )
                    }
                }
            )
        }
        .padding(.vertical, 12)
        .onAppear { startOrStopGlow() }
        .onChange(of: inputState) { _ in startOrStopGlow() }
    }

    private func startOrStopGlow() {
        if case .recording = inputState {
            glowRotation = 0
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                glowRotation = 360
            }
        } else {
            withAnimation(.none) { glowRotation = 0 }
        }
    }
}
