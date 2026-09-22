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

import Foundation
import SwiftUI
import Combine
import AEPCore
import AEPServices

/// Main controller orchestrating chat functionality.
/// Manages messages, chat state, and coordinates between services.
@MainActor
final class ChatController: ObservableObject {
    // MARK: - Published State

    @Published var messages: [Message] = []
    @Published var chatState: ChatState = .idle
    @Published var userScrollTick: Int = 0
    @Published var userMessageToScrollId: UUID?
    @Published var showPermissionDialog: Bool = false
    @Published var audioLevel: Float = 0

    /// Mirror of `inputController.state`, updated only on state transitions (not per-keystroke text
    /// changes). Lets views react to input state without observing `InputController` directly.
    @Published private(set) var composerState: InputState = .empty

    /// Copy rendered into the transcript when a turn fails. Pushed in from the view's theme (see
    /// `ChatView`) because the theme lives in the SwiftUI environment rather than on the session.
    var networkErrorMessage: String = ConciergeCopy.defaultErrorNetwork

    // MARK: - Input Controller

    let inputController = InputController()

    var inputText: String { inputController.data.text }
    var inputState: InputState { inputController.state }

    // MARK: - Private Properties

    private let LOG_TAG = "ChatController"
    private let chatService: ConciergeChatService
    private let configuration: ConciergeConfiguration?
    private let speechController: SpeechController
    private let dispatch: ((_ event: Event) -> Void)?

    private var welcomeMessagesLoaded: Bool = false

    /// The in-flight handoff's completion and the caps that bound it. A single set is enough: the
    /// `chatState != .processing` guard admits only one handoff turn at a time.
    ///
    /// `handoffInFlight` is tracked separately from `handoffCompletion` because the completion is
    /// optional. Keying the caps off the completion would silently disable them for a caller that
    /// passed `nil`, leaving a stalled turn parked in `.processing` forever.
    private var handoffInFlight = false
    private var handoffCompletion: ((ConciergeError?) -> Void)?
    private var firstChunkWorkItem: DispatchWorkItem?
    private var turnWorkItem: DispatchWorkItem?

    /// Injectable so tests can exercise the caps without waiting out the production values.
    private let handoffFirstChunkTimeout: TimeInterval
    private let handoffTurnTimeout: TimeInterval

    private var latestSources: [Source] = []
    private var latestLinkHints: [LinkHint] = []
    private var latestPromptSuggestions: [String] = []
    private var chatOpenTime: Date?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var isRecording: Bool { inputState == .recording }
    var isProcessing: Bool { chatState == .processing }
    var composerEditable: Bool { chatState != .processing }
    var micEnabled: Bool { chatState == .idle }
    var sendEnabled: Bool { chatState == .idle && inputController.data.canSend }

    /// Whether the transcript holds at least one real turn. Welcome content doesn't count.
    ///
    /// Deliberately not "has the *user* sent a message": a data handoff appends only agent-styled
    /// messages, so a checkout-driven conversation would otherwise still look untouched.
    var hasConversationStarted: Bool {
        messages.contains { message in
            switch message.template {
            case .welcomeHeader, .welcomePromptSuggestion:
                return false
            default:
                return true
            }
        }
    }

    // MARK: - Initialization

    init(configuration: ConciergeConfiguration, speechCapturer: SpeechCapturing?, speaker: TextSpeaking?, dispatch: ((_ event: Event) -> Void)? = nil, urlSessionConfiguration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        self.chatService = ConciergeChatService(configuration: configuration, urlSessionConfiguration: urlSessionConfiguration)
        self.speechController = SpeechController(capturer: speechCapturer, speaker: speaker)
        self.dispatch = dispatch
        self.handoffTurnTimeout = ConciergeConstants.Request.DATA_HANDOFF_TURN_TIMEOUT
        self.handoffFirstChunkTimeout = ConciergeConstants.Request.DATA_HANDOFF_FIRST_CHUNK_TIMEOUT

        configureSpeech()
        observeComposerState()
    }

    #if DEBUG
    // Internal for testing only
    init(configuration: ConciergeConfiguration?, chatService: ConciergeChatService, speechCapturer: SpeechCapturing?, speaker: TextSpeaking?, dispatch: ((_ event: Event) -> Void)? = nil, handoffTurnTimeout: TimeInterval = ConciergeConstants.Request.DATA_HANDOFF_TURN_TIMEOUT, handoffFirstChunkTimeout: TimeInterval = ConciergeConstants.Request.DATA_HANDOFF_FIRST_CHUNK_TIMEOUT) {
        self.configuration = configuration
        self.chatService = chatService
        self.speechController = SpeechController(capturer: speechCapturer, speaker: speaker)
        self.dispatch = dispatch
        self.handoffTurnTimeout = handoffTurnTimeout
        self.handoffFirstChunkTimeout = handoffFirstChunkTimeout

        configureSpeech()
        observeComposerState()
    }
    #endif

    // MARK: - Input Handling

    private func observeComposerState() {
        inputController.$state
            .sink { [weak self] newState in
                self?.composerState = newState
            }
            .store(in: &cancellables)
    }

    func applyTextChange(_ newText: String) {
        inputController.applyTextChange(newText)
    }

    // MARK: - Speech Output

    func speak(_ text: String) {
        speechController.speak(text)
    }

    // MARK: - Mic Control

    /// Applies voice capture settings from the current theme before recording starts.
    func applyVoiceInputBehavior(_ input: ConciergeInputBehavior) {
        speechController.configureSilenceDetection(threshold: input.silenceThreshold, duration: input.silenceDuration)
    }

    func toggleMic(currentSelectionLocation: Int) {
        if isRecording { completeMic() } else { startRecording(currentSelectionLocation: currentSelectionLocation) }
    }

    func cancelMic() {
        guard isRecording else {
            Log.warning(label: LOG_TAG, "cancelMic ignored. Expected inputState to be 'recording', but was '\(inputState)'.")
            return
        }
        inputController.apply(.cancelRecording)
        speechController.endCapture { _, _ in }
    }

    func completeMic() {
        guard isRecording else {
            Log.warning(label: LOG_TAG, "completeMic ignored. Expected inputState to be 'recording', but was '\(inputState)'.")
            return
        }
        inputController.apply(.recordingComplete)
        speechController.endCapture { [weak self] transcript, _ in
            Task { @MainActor in
                if let transcript = transcript, !transcript.isEmpty {
                    self?.inputController.apply(.transcriptionComplete(transcript))
                } else {
                    self?.inputController.apply(.transcriptionError("empty transcript"))
                }
            }
        }
    }

    func startRecording(currentSelectionLocation: Int) {
        guard chatState == .idle else {
            Log.warning(label: LOG_TAG, "startRecording ignored. Expected chatState to be 'idle', but was '\(chatState)'.")
            return
        }
        guard inputState == .empty || inputState == .editing || {
            if case .error = inputState { return true } else { return false }
        }() else {
            Log.warning(label: LOG_TAG, "startRecording ignored. Expected inputState to be 'empty' or 'editing', but was '\(inputState)'.")
            return
        }
        guard speechController.isCapturerAvailable else {
            Log.warning(label: LOG_TAG, "startRecording ignored. Speech capturer instance is nil.")
            return
        }

        // Only request permissions if the user has never been asked before
        if speechController.hasNeverBeenAskedForPermission {
            Log.debug(label: LOG_TAG, "Requesting speech and microphone permissions for the first time.")
            speechController.requestPermissions { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    // After user responds to system prompts, check if permissions were granted
                    if self.speechController.isAvailable {
                        Log.debug(label: self.LOG_TAG, "Permissions granted. Starting recording.")
                        self.beginCaptureSession(currentSelectionLocation: currentSelectionLocation)
                    } else {
                        Log.debug(label: self.LOG_TAG, "Permissions not granted after request. Showing permission dialog.")
                        self.showPermissionDialog = true
                    }
                }
            }
            return
        }

        // Always check if permissions are available before proceeding
        if !speechController.isAvailable {
            // Permissions were asked but not granted - show custom dialog
            Log.debug(label: LOG_TAG, "Speech or microphone permissions not granted. Showing permission dialog.")
            showPermissionDialog = true
            return
        }

        // Permissions granted - proceed with recording
        beginCaptureSession(currentSelectionLocation: currentSelectionLocation)
    }

    private func beginCaptureSession(currentSelectionLocation: Int) {
        speechController.setAudioLevelHandler { [weak self] level in
            self?.audioLevel = level
        }
        speechController.setSilenceHandler { [weak self] in
            self?.completeMic()
        }
        inputController.apply(.startMic(currentSelectionLocation: currentSelectionLocation))
        speechController.beginCapture()
    }

    // MARK: - Permission Dialog

    func dismissPermissionDialog() {
        showPermissionDialog = false
    }

    func requestOpenSettings() {
        showPermissionDialog = false
    }

    // MARK: - Message Sending

    func sendMessage(isUser: Bool) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Log.warning(label: LOG_TAG, "sendMessage ignored. Expected non-empty text, but was empty.")
            return
        }
        guard chatState == .idle else {
            Log.warning(label: LOG_TAG, "sendMessage ignored. Expected chatState to be 'idle', but was '\(chatState)'.")
            return
        }

        if isRecording { completeMic() }

        // Clear input via controller to keep state machine consistent
        inputController.apply(.sendMessage)

        let newMessage = Message(template: .basic(isUserMessage: isUser), messageBody: text)
        messages.append(newMessage)

        if isUser {
            // Store the user message ID first
            scrollToTop(messageId: newMessage.id)
        }

        if isUser {
            dispatchTrackingEvent(.querySubmitted(query: text))
            chatState = .processing
            streamAgentResponse(for: text)
        } else {
            clearState()
        }
    }

    /// Forwards an app-originated data-handoff turn (e.g. a checkout outcome) to Brand Concierge.
    /// The routing hint never renders; only `localMessage` and the eventual reply do. The turn is
    /// scrolled to the top like `sendMessage` does, since a handoff is triggered from app UI rather
    /// than the composer and the transcript would otherwise stay where the user left it.
    ///
    /// Returns `false` without starting anything when a turn is already in flight:
    /// `ConciergeChatService` keeps a single `dataTask`/handler pair per instance, so a second
    /// concurrent turn would strand the first one's completion. `.error` is *not* in flight.
    @discardableResult
    func handleDataHandoff(routingHint: String,
                           xdmFields: [String: Any],
                           localMessage: String? = nil,
                           completion: ((ConciergeError?) -> Void)? = nil) -> Bool {
        guard chatState != .processing else {
            Log.warning(label: LOG_TAG, "handleDataHandoff ignored. A Concierge turn is already in progress.")
            return false
        }

        var anchorMessageId: UUID?
        if let localMessage, !localMessage.isEmpty {
            let message = Message(template: .basic(isUserMessage: false), messageBody: localMessage)
            messages.append(message)
            anchorMessageId = message.id
        }

        chatState = .processing
        armHandoffTimeouts(completion)
        streamAgentResponse(for: routingHint, extraXDMFields: xdmFields, rendersFailures: false) { [weak self] error in
            self?.finishHandoff(error)
        }

        // `streamAgentResponse` appends its streaming placeholder synchronously, so with no local
        // message that placeholder is now the last message and becomes the anchor instead.
        if let anchorMessageId = anchorMessageId ?? messages.last?.id {
            scrollToTop(messageId: anchorMessageId)
        }
        return true
    }

    /// Arms the two caps that bound a handoff turn.
    ///
    /// They answer different failure modes. The first-chunk cap catches a backend that never
    /// responds at all, which is the common hang and worth failing fast on. The turn cap is the
    /// hard ceiling that makes `sendDataHandoff`'s completion a promise; it has to stay generous,
    /// because cancelling a turn that is actively streaming throws away a reply the user was about
    /// to see. Without the ceiling the event hub's timer would become the de-facto bound, which is
    /// what produced the original mismatch: a long-but-healthy turn rendered while the app was
    /// told it had failed.
    private func armHandoffTimeouts(_ completion: ((ConciergeError?) -> Void)?) {
        handoffInFlight = true
        handoffCompletion = completion

        firstChunkWorkItem = scheduleHandoffTimeout(after: handoffFirstChunkTimeout,
                                                    reason: "produced no response")
        turnWorkItem = scheduleHandoffTimeout(after: handoffTurnTimeout,
                                              reason: "exceeded its wall-clock cap")
    }

    private func scheduleHandoffTimeout(after interval: TimeInterval, reason: String) -> DispatchWorkItem {
        let workItem = DispatchWorkItem {
            Task { @MainActor [weak self] in
                guard let self = self, self.handoffInFlight else { return }
                Log.warning(label: self.LOG_TAG, "Data handoff turn \(reason).")
                self.finishHandoff(.timeout(Int(interval)))

                // Reported first, then cancelled: the cancellation reaches the delegate as an
                // ordinary failure, which unwinds the transcript and chat state through the
                // existing error branch. Its completion call is swallowed, as `finishHandoff`
                // fires once.
                self.chatService.cancelActiveStream()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        return workItem
    }

    /// Disarms the first-chunk cap once the service starts streaming. The turn cap stays armed.
    ///
    /// No-ops for an ordinary typed turn, which has no handoff caller waiting on it.
    private func noteHandoffChunkReceived() {
        guard handoffInFlight else { return }
        firstChunkWorkItem?.cancel()
        firstChunkWorkItem = nil
    }

    /// Reports a handoff outcome to its caller exactly once and disarms both caps.
    private func finishHandoff(_ error: ConciergeError?) {
        handoffInFlight = false
        firstChunkWorkItem?.cancel()
        firstChunkWorkItem = nil
        turnWorkItem?.cancel()
        turnWorkItem = nil

        guard let completion = handoffCompletion else { return }
        handoffCompletion = nil
        completion(error)
    }

    /// Scrolls the transcript so `messageId` sits at the top, leaving the rest of the screen for
    /// the response that follows.
    ///
    /// The tick is bumped on the next main-queue pass so the id is published *before* the change
    /// `MessageListView` observes; a same-pass update would scroll to the previous turn's anchor.
    private func scrollToTop(messageId: UUID) {
        userMessageToScrollId = messageId
        DispatchQueue.main.async {
            self.userScrollTick &+= 1
        }
    }

    // MARK: - Welcome Content

    /// Loads initial welcome header and examples if not already loaded.
    func loadWelcomeIfNeeded(theme: ConciergeTheme) async {
        // Prevent loading if already loaded OR if messages is not empty
        guard !welcomeMessagesLoaded && messages.isEmpty else { return }
        welcomeMessagesLoaded = true

        // Prefer welcome content provided by the theme when available.
        let title = theme.copy.welcomeHeading
        let body = theme.copy.welcomeSubheading
        let examples = theme.welcomeExamples

        if !title.isEmpty || !body.isEmpty {
            messages.append(Message(template: .welcomeHeader(title: title, body: body)))
        }

        if !examples.isEmpty {
            for example in examples {
                let url = example.image.flatMap { URL(string: $0) }
                let background = example.backgroundColor?.color ?? Color(UIColor.secondarySystemBackground)
                let message = Message(
                    template: .welcomePromptSuggestion(
                        imageSource: .remote(url),
                        text: example.text,
                        background: background
                    )
                )
                messages.append(message)
            }
        }

        dispatchTrackingEvent(.sessionInitialized)
    }

    // MARK: - Feedback

    func sendFeedbackFor(messageId: UUID?, with feedbackPayload: FeedbackPayload) {
        guard let messageId = messageId, let index = messages.firstIndex(where: { $0.id == messageId }) else {
            Log.debug(label: LOG_TAG, "Unable to send feedback, the message was not retrievable from the chat.")
            return
        }

        guard let configuration = configuration else {
            Log.debug(label: LOG_TAG, "Unable to send feedback, configuration is not available.")
            return
        }

        // Get the message information for which feedback was provided
        var currentMessage = messages[index]

        guard let messagePayload = currentMessage.payload else {
            Log.debug(label: LOG_TAG, "Unable to send feedback, message payload is not available.")
            return
        }

        // Attach sentiment
        currentMessage.feedbackSentiment = feedbackPayload.sentiment

        // Write the updated message back to the array so UI updates
        messages[index] = currentMessage

        // Generate an edge event to track the feedback
        let feedbackEventData: [String: Any] = [
            ConciergeConstants.Request.Keys.XDM: [
                ConciergeConstants.Request.Keys.EVENT_TYPE: ConciergeConstants.Request.EventType.CONVERSATION_FEEDBACK,
                // Forward identityMap verbatim; falls back to an ECID-only map
                ConciergeConstants.Request.Keys.IDENTITY_MAP: configuration.identityMapPayload,
                ConciergeConstants.Request.Keys.CONVERSATION: [
                    ConciergeConstants.Request.Keys.Feedback.FEEDBACK: [
                        ConciergeConstants.Request.Keys.Feedback.SOURCE: ConciergeConstants.Request.Values.Feedback.END_USER,
                        ConciergeConstants.Request.Keys.Feedback.RAW: [
                            [
                                ConciergeConstants.Request.Keys.Feedback.TEXT: feedbackPayload.notes,
                                ConciergeConstants.Request.Keys.Feedback.PURPOSE: ConciergeConstants.Request.Values.Feedback.USER_INPUT
                            ]
                        ],
                        ConciergeConstants.Request.Keys.Feedback.RATING: [
                            ConciergeConstants.Request.Keys.Feedback.SCORE: feedbackPayload.sentiment == .positive ? 1 : 0,
                            ConciergeConstants.Request.Keys.Feedback.CLASSIFICATION: feedbackPayload.sentiment.thumbsValue(),
                            ConciergeConstants.Request.Keys.Feedback.REASONS: feedbackPayload.selectedOptions
                        ]
                    ],
                    ConciergeConstants.Request.Keys.Feedback.CONVERSATION_ID: messagePayload.conversationId ?? "unknown",
                    ConciergeConstants.Request.Keys.Feedback.TURN_ID: messagePayload.interactionId ?? "unknown"
                ]
            ]
        ]

        Task { [weak self] in
            guard let self else { return }
            let token = await ConciergeAuthTokenResolver.shared.resolveToken()
            self.chatService.sendFeedback(data: feedbackEventData, token: token)
        }

        dispatchTrackingEvent(.feedbackSubmitted(
            conversationId: messagePayload.conversationId ?? "unknown",
            interactionId: messagePayload.interactionId ?? "unknown",
            feedbackType: feedbackPayload.sentiment == .positive ? "positive" : "negative",
            selectedOptions: feedbackPayload.selectedOptions,
            notes: feedbackPayload.notes
        ))
    }

    // MARK: - Tracking

    func trackChatOpened() {
        let now = Date()
        chatOpenTime = now
        let epochTime = Int64(now.timeIntervalSince1970 * 1000)
        dispatchTrackingEvent(.chatOpened(epochTime: epochTime))
    }

    func trackChatClosed() {
        let now = Date()
        let epochTime = Int64(now.timeIntervalSince1970 * 1000)
        let durationMillis = chatOpenTime.map { Int64(now.timeIntervalSince($0) * 1000) } ?? 0
        chatOpenTime = nil
        dispatchTrackingEvent(.chatClosed(epochTime: epochTime, durationMillis: durationMillis))
    }

    func trackPromptSuggestionClicked(suggestion: String) {
        dispatchTrackingEvent(.promptSuggestionClicked(suggestion: suggestion))
    }

    func trackWelcomePromptSuggestionClicked(suggestion: String) {
        dispatchTrackingEvent(.welcomePromptSuggestionClicked(suggestion: suggestion))
    }

    func trackMicButtonClicked() {
        dispatchTrackingEvent(.micButtonClicked)
    }

    func trackDisclaimerLinkClicked(url: URL) {
        dispatchTrackingEvent(.disclaimerLinkClicked(url: url.absoluteString))
        trackLinkClicked(url: url.absoluteString, origin: ConciergeConstants.TrackingEvent.LinkClickOrigin.DISCLAIMER)
    }

    func trackCtaButtonClicked(label: String, url: String) {
        dispatchTrackingEvent(.ctaButtonClicked(label: label, linkUrl: url))
        trackLinkClicked(url: url, origin: ConciergeConstants.TrackingEvent.LinkClickOrigin.CTA)
    }

    func trackCardClicked(cardData: ProductCardData) {
        var element: [String: Any] = ["productName": cardData.title]
        if let subtitle = cardData.subtitle { element["productDescription"] = subtitle }
        if let url = cardData.destinationURL?.absoluteString { element["productPageURL"] = url }
        if let price = cardData.price { element["productPrice"] = price }
        if let badge = cardData.badge { element["productBadge"] = badge }
        dispatchTrackingEvent(.cardClicked(element: element))
        if let url = cardData.destinationURL?.absoluteString {
            trackLinkClicked(url: url, origin: ConciergeConstants.TrackingEvent.LinkClickOrigin.PRODUCT_CARD)
        }
    }

    func trackLinkClicked(url: String, origin: String) {
        dispatchTrackingEvent(.linkClicked(url: url, origin: origin))
    }

    private func dispatchTrackingEvent(_ trackingEvent: ConciergeTrackingEvent) {
        let event = trackingEvent.toEvent()
        Log.debug(label: LOG_TAG, "Dispatching tracking event - name: \(event.name), type: \(event.type), source: \(event.source), data: \(event.data ?? [:])")
        dispatch?(event)
    }

    // MARK: - Private Methods

    private func configureSpeech() {
        speechController.configureForStreaming { [weak self] text in
            Task { @MainActor in
                self?.inputController.apply(.streamingPartial(text))
            }
        }
    }

    /// - Parameter rendersFailures: Whether a failed turn leaves a notice in the transcript. True
    ///   for a turn the user typed, since they are waiting on a visible answer. False for a data
    ///   handoff: the user never asked for it and may not know one was sent, so an error bubble
    ///   would appear unprompted. The failure still reaches the app through `completion`.
    private func streamAgentResponse(for query: String,
                                     extraXDMFields: [String: Any]? = nil,
                                     rendersFailures: Bool = true,
                                     completion: ((ConciergeError?) -> Void)? = nil) {
        let streamingMessageIndex = messages.count
        messages.append(Message(template: .basic(isUserMessage: false), messageBody: ""))

        // Accumulators are used to handle the progressive building up of response content from the server
        // and to be able to effectively do a diff of what has already been received and what is new.
        var accumulatedContent = ""
        var latestElements: [MultimodalElement] = []
        var responseStartedDispatched = false

        // Resolve the auth token off the UI thread, then send the turn on the main actor.
        //
        // `self` is captured strongly on purpose: the caller's `completion` is only guaranteed
        // exactly-once by the `defer` inside `onComplete`, which isn't registered until
        // `streamChat` is called below. A weak capture could drop the completion entirely if the
        // controller were released before this task first resumed. The hold is bounded by one turn.
        Task { [self] in
            let token = await ConciergeAuthTokenResolver.shared.resolveToken()
            self.chatService.streamChat(query, token: token, extraXDMFields: extraXDMFields,
            onChunk: { [weak self] payload in
                Task { @MainActor in
                    guard let self = self else { return }

                    // The backend is alive, so the fast "never answered" cap has done its job.
                    self.noteHandoffChunkReceived()

                    let state = payload.state

                    // Serializing + pretty-printing the response is only useful for local debugging,
                    #if DEBUG
                    if let response = payload.response {
                        if let data = try? JSONEncoder().encode(response),
                           let json = String(data: data, encoding: .utf8) {
                            Log.debug(label: self.LOG_TAG, "SSE chunk (state=\(state ?? "n/a")): \(json.prettyPrintedJSON())")
                        }
                    } else {
                        Log.debug(label: self.LOG_TAG, "SSE chunk: state=\(state ?? "n/a") (no response)")
                    }
                    #endif

                    // Dispatch responseStarted exactly once per turn, on the first chunk that
                    // carries any user-visible content (text OR multimodal elements). Mirrors
                    // the Android `hasVisibleContent` gate so cards-only responses still produce
                    // a paired responseStarted/responseCompleted, and pure heartbeat chunks
                    // (response present but empty) do not.
                    let chunkMessage = payload.response?.message ?? ""
                    let chunkElements = payload.response?.multimodalElements?.elements ?? []
                    let hasVisibleContent = !chunkMessage.isEmpty || !chunkElements.isEmpty
                    if hasVisibleContent && !responseStartedDispatched {
                        responseStartedDispatched = true
                        self.dispatchTrackingEvent(.responseStarted(
                            conversationId: payload.conversationId ?? "unknown",
                            interactionId: payload.interactionId ?? "unknown"
                        ))
                    }

                    // Handle messages
                    if let message = payload.response?.message {
                        if state == ConciergeConstants.StreamState.IN_PROGRESS {
                            accumulatedContent += message
                            Log.trace(label: self.LOG_TAG, "SSE chunk (len=\(message.count)): \"\(message)\"")
                            Log.trace(label: self.LOG_TAG, "Accumulated (len=\(accumulatedContent.count))")

                            // Update the streaming message with accumulated content (preserve id)
                            if streamingMessageIndex < self.messages.count {
                                var current = self.messages[streamingMessageIndex]
                                current.messageBody = accumulatedContent
                                current.payload = payload
                                self.messages[streamingMessageIndex] = current
                            }
                        } else if state == ConciergeConstants.StreamState.COMPLETED {
                            let fullText = message
                            Log.trace(label: self.LOG_TAG, "Completion received. Full text length=\(fullText.count)")

                            if streamingMessageIndex < self.messages.count {
                                var current = self.messages[streamingMessageIndex]
                                current.messageBody = fullText
                                current.payload = payload
                                self.messages[streamingMessageIndex] = current
                            }

                            accumulatedContent = fullText
                        }
                    }

                    // Capture multimodal elements for rendering on completion
                    if let elements = payload.response?.multimodalElements?.elements, !elements.isEmpty {
                        latestElements = elements
                    }

                    // Capture prompt suggestions if present
                    if let suggestions = payload.response?.promptSuggestions, !suggestions.isEmpty {
                        self.latestPromptSuggestions = suggestions
                    }

                    // Capture sources from payload as they arrive (used on completion)
                    if let sources = payload.response?.sources {
                        self.latestSources = sources
                    }

                    // Capture link hints from payload as they arrive (used on completion)
                    if let hints = payload.response?.linkHints, !hints.isEmpty {
                        self.latestLinkHints = hints
                    }
                }
            },
            onComplete: { [weak self] error in
                Task { @MainActor in
                    // The handoff caller must hear back exactly once on every path out of this
                    // closure, including the early `return`s below and a deallocated controller.
                    var handoffError: ConciergeError? = error
                    defer { completion?(handoffError) }

                    guard let self = self else {
                        // The session went away mid-stream; nothing was rendered.
                        handoffError = handoffError ?? .unknown
                        return
                    }

                    if let error = error {
                        Log.error(label: self.LOG_TAG, "Streaming error: \(error)")
                        self.dispatchTrackingEvent(.errorOccurred(errorMessage: error.localizedDescription))

                        if streamingMessageIndex < self.messages.count {
                            self.messages.remove(at: streamingMessageIndex)
                        }

                        // A failed turn is a *finished* turn: surface the failure and return to
                        // idle. Parking in `.error` would deadlock the chat - `sendMessage`,
                        // `sendEnabled`, and `micEnabled` all require `.idle`, and the only path
                        // back to `.idle` runs inside a turn those guards prevent from starting.
                        if rendersFailures {
                            self.messages.append(Message(template: .basic(isUserMessage: false),
                                                         messageBody: self.networkErrorMessage))
                        }

                        self.clearState()
                    } else if accumulatedContent.isEmpty && latestElements.isEmpty {
                        handoffError = .invalidResponseData
                        // Genuinely empty response — no text and no multimodal elements.
                        if streamingMessageIndex < self.messages.count {
                            self.messages.remove(at: streamingMessageIndex)
                        }

                        if rendersFailures {
                            self.messages.append(Message(template: .basic(isUserMessage: false), messageBody: "Sorry, I wasn't able to get a response from the Concierge Service. \n\nPlease try again later."))
                        }

                        self.clearState()
                    } else {
                        var completedPayload: ConversationPayload?
                        if streamingMessageIndex < self.messages.count {
                            var current = self.messages[streamingMessageIndex]
                            current.messageBody = accumulatedContent
                            current.shouldSpeakMessage = !accumulatedContent.isEmpty
                            if !self.latestSources.isEmpty {
                                Log.trace(label: self.LOG_TAG, "Using sources: count=\(self.latestSources.count)")
                                current.sources = self.latestSources
                            }
                            if !self.latestLinkHints.isEmpty {
                                Log.trace(label: self.LOG_TAG, "Using linkHints: count=\(self.latestLinkHints.count)")
                                current.linkHints = self.latestLinkHints
                            }
                            current.feedbackEligible = current.payload?.response?.feedback?.eligible ?? false
                            current.isStreamComplete = true
                            self.messages[streamingMessageIndex] = current
                            completedPayload = current.payload
                        }

                        guard let completedPayload else {
                            Log.warning(label: self.LOG_TAG, "responseCompleted skipped: streaming message index out of bounds")
                            self.clearState()
                            return
                        }

                        // A cards-only response has nothing for the text bubble, so drop the
                        // placeholder rather than leave an empty one above the cards. Deliberately
                        // after the guard above: removing it on a path that then returns early
                        // would strip the turn's only message and still report success.
                        if accumulatedContent.isEmpty && !latestElements.isEmpty,
                           streamingMessageIndex < self.messages.count {
                            self.messages.remove(at: streamingMessageIndex)
                        }
                        self.dispatchTrackingEvent(.responseCompleted(
                            conversationId: completedPayload.conversationId ?? "unknown",
                            interactionId: completedPayload.interactionId ?? "unknown"
                        ))

                        // Render multimodal elements (cards, CTAs) from the completed response
                        if !latestElements.isEmpty {
                            self.renderMultimodalElements(latestElements)
                        }

                        // Append prompt suggestions as their own message bubbles at the end
                        if !self.latestPromptSuggestions.isEmpty {
                            for suggestion in self.latestPromptSuggestions {
                                self.messages.append(Message(template: .promptSuggestion(text: suggestion)))
                            }
                        }

                        self.clearState()
                    }
                }
            }
            )
        }
    }

    private func clearState() {
        chatState = .idle
        latestSources = []
        latestLinkHints = []
        latestPromptSuggestions = []
    }

    /// Appends multimodal elements to `messages`, respecting their relative order from
    /// the server. Card-type elements are collapsed into a single card or carousel at
    /// the position of the first card encountered.
    private func renderMultimodalElements(_ elements: [MultimodalElement]) {
        let cardElements = elements.filter { $0.elementType != .ctaButton }

        // If any cards exist in the multimodal elements list, 
        // resolves to either single card or carousel of cards depending on number of card elements
        let cardMessage: Message? = {
            if cardElements.count == 1, let card = cardElements.first, let entityInfo = card.entityInfo {
                let cardData = ProductCardData(entityInfo: entityInfo, element: card)
                return Message(template: .productCard(cardData))
            } else if cardElements.count > 1 {
                var carouselItems: [Message] = []
                for card in cardElements {
                    guard let entityInfo = card.entityInfo else { continue }
                    let cardData = ProductCardData(entityInfo: entityInfo, element: card)
                    carouselItems.append(Message(template: .productCarouselCard(cardData)))
                }
                return Message(template: .carouselGroup(carouselItems))
            }
            return nil
        }()

        var cardElementEmitted = false

        for element in elements {
            if element.elementType == .ctaButton {
                guard let action = element.entityInfo?.primary else {
                    Log.warning(label: LOG_TAG, "Skipping ctaButton element '\(element.id ?? "unknown")': missing entity_info.primary.")
                    continue
                }
                messages.append(Message(template: .ctaButton(action)))
            } else if !cardElementEmitted {
                if let cardMessage = cardMessage {
                    messages.append(cardMessage)
                }
                cardElementEmitted = true
            }
        }

        let elementDicts: [[String: Any]] = cardElements.compactMap { element in
            guard let entityInfo = element.entityInfo else { return nil }
            var dict: [String: Any] = [:]
            if let name = entityInfo.productName { dict["productName"] = name }
            if let url = entityInfo.productPageURL { dict["productPageURL"] = url }
            if let price = entityInfo.productPrice { dict["productPrice"] = price }
            return dict
        }
        guard !elementDicts.isEmpty else { return }
        let displayMode = elementDicts.count == 1 ? "single" : "carousel"
        dispatchTrackingEvent(.cardsRendered(displayMode: displayMode, elements: elementDicts))
    }
}

// MARK: - Array Safe Access Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
