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

    /// The transcript, and the single source of truth for native card lifetime. Any write that drops a
    /// card's row - identity reset, rollback, or a direct edit - disposes that card here, so there is no
    /// removal path that can leave a live card behind. Every write is checked, including streaming
    /// updates; the check returns immediately while no native cards exist.
    @Published var messages: [Message] = [] {
        didSet { nativeCards.reconcile(with: messages) }
    }

    @Published private(set) var chatState: ChatState = .idle
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
    /// The conversation this controller draws. It owns the turn engine, turn analytics, handoffs
    /// and feedback; the controller owns only what is on screen. Replaced, keeping the transcript on
    /// screen, when its session expires: a conversation never moves to another session.
    private(set) var conversation: ConciergeConversation
    private let makeConversation: () -> ConciergeConversation
    var core: ConciergeConversationCore { conversation.core }
    let configuration: ConciergeConfiguration?
    private let speechController: SpeechController
    var lastTurnSessionID: String? { conversation.lastTurnSessionID }
    private let identityGeneration: Int
    @Published private(set) var endedForIdentityReset = false
    var conversationID: String? { messages.compactMap { $0.payload?.conversationId }.last }
    /// Whether the user can still act. An expired session doesn't count against it: the next turn
    /// renews the conversation.
    private var identityReady: Bool {
        guard !endedForIdentityReset, !core.isEnded else { return false }
        return conversation.isLive || conversation.state == .closed(.sessionExpired)
    }

    private var welcomeMessagesLoaded: Bool = false

    /// The native cards behind this transcript's card rows. Views read it to resolve a row's card.
    let nativeCards = NativeCardStore()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var isRecording: Bool { inputState == .recording }
    var isProcessing: Bool { chatState == .processing }
    var composerEditable: Bool { identityReady && chatState != .processing }
    var micEnabled: Bool { identityReady && chatState == .idle }
    var sendEnabled: Bool { identityReady && chatState == .idle && inputController.data.canSend }

    /// Whether the transcript holds at least one real turn. Welcome content doesn't count.
    ///
    /// Deliberately not "has the *user* sent a message": a data handoff appends only agent-styled
    /// messages, so a checkout-driven conversation would otherwise still look untouched.
    var hasConversationStarted: Bool {
        messages.contains { !$0.isWelcomeContent }
    }

    // MARK: - Initialization

    init(configuration: ConciergeConfiguration, speechCapturer: SpeechCapturing?, speaker: TextSpeaking?, dispatch: ((_ event: Event) -> Void)? = nil, urlSessionConfiguration: URLSessionConfiguration = .default, identityGeneration: Int? = nil, appState: ConciergeAppState = .shared) {
        let generation = identityGeneration ?? ConciergeIdentityBoundary.shared.synchronized {
            ConciergeIdentityBoundary.shared.generation
        }
        self.identityGeneration = generation
        self.configuration = configuration
        let makeConversation: () -> ConciergeConversation = {
            let core = ConciergeConversationCore(configuration: configuration, urlSessionConfiguration: urlSessionConfiguration,
                                                 identityGeneration: generation, dispatch: { dispatch?($0) })
            return ConciergeConversation(core: core, dispatch: { dispatch?($0) }, appState: appState)
        }
        self.makeConversation = makeConversation
        self.conversation = makeConversation()
        self.speechController = SpeechController(capturer: speechCapturer, speaker: speaker, identityGeneration: generation)
        conversation.presenter = self
        ConciergeActiveConversation.activate(conversation)

        configureSpeech()
        observeComposerState()
    }

    #if DEBUG
    // Internal for testing only
    init(configuration: ConciergeConfiguration?, chatService: ConciergeChatService, speechCapturer: SpeechCapturing?, speaker: TextSpeaking?, dispatch: ((_ event: Event) -> Void)? = nil, handoffTurnTimeout: TimeInterval = ConciergeConstants.Request.DATA_HANDOFF_TURN_TIMEOUT, handoffFirstChunkTimeout: TimeInterval = ConciergeConstants.Request.DATA_HANDOFF_FIRST_CHUNK_TIMEOUT, appState: ConciergeAppState = .shared, backgroundRecoveryMaxAge: TimeInterval = ConciergeConstants.Session.TTL_SECONDS) {
        let generation = ConciergeIdentityBoundary.shared.synchronized {
            ConciergeIdentityBoundary.shared.generation
        }
        self.identityGeneration = generation
        self.configuration = configuration
        let makeConversation: () -> ConciergeConversation = {
            let core = ConciergeConversationCore(configuration: configuration ?? ConciergeConfiguration(), transport: chatService,
                                                 identityGeneration: generation, dispatch: { dispatch?($0) })
            return ConciergeConversation(core: core, dispatch: { dispatch?($0) }, appState: appState,
                                         handoffLimits: HandoffLimits(noResponse: handoffFirstChunkTimeout,
                                                                      ceiling: handoffTurnTimeout),
                                         backgroundRecoveryMaxAge: backgroundRecoveryMaxAge)
        }
        self.makeConversation = makeConversation
        self.conversation = makeConversation()
        self.speechController = SpeechController(capturer: speechCapturer, speaker: speaker, identityGeneration: generation)
        conversation.presenter = self

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
        guard identityReady else { return }
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
        guard identityReady else { return }
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
                guard let self, self.identityReady else { return }
                if let transcript = transcript, !transcript.isEmpty {
                    self.inputController.apply(.transcriptionComplete(transcript))
                } else {
                    self.inputController.apply(.transcriptionError("empty transcript"))
                }
            }
        }
    }

    func startRecording(currentSelectionLocation: Int) {
        guard identityReady else { return }
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
                    guard let self = self, self.identityReady else { return }
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
        guard identityReady else { return }
        speechController.setAudioLevelHandler { [weak self] level in
            guard let self, self.identityReady else { return }
            self.audioLevel = level
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

    /// Sends the composer text. The conversation decides whether a turn can start; on `.accepted`
    /// it has already added the user's row (`conversationDidAppendUserMessage`).
    func sendMessage(isUser: Bool) {
        ConciergeIdentityBoundary.shared.synchronized {
            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUser else {
                guard identityReady, !text.isEmpty else { return }
                inputController.apply(.sendMessage)
                messages.append(Message(template: .basic(isUserMessage: false), messageBody: text))
                return
            }
            guard chatState == .idle else {
                Log.warning(label: LOG_TAG, "sendMessage ignored. Expected chatState to be 'idle', but was '\(chatState)'.")
                return
            }
            renewConversationIfSessionExpired()
            let wasRecording = isRecording
            let result = conversation.send(text)
            guard result == .accepted else {
                Log.warning(label: LOG_TAG, "sendMessage ignored: \(result).")
                return
            }
            if wasRecording { completeMic() }
            inputController.apply(.sendMessage)
        }
    }

    /// Starts a new conversation, on a new session, when the current one's session has expired.
    /// The transcript on screen stays.
    private func renewConversationIfSessionExpired() {
        guard identityReady, conversation.closeIfSessionExpired(),
              conversation.state == .closed(.sessionExpired) else { return }
        Log.debug(label: LOG_TAG, "Session expired; continuing the chat in a new conversation.")
        conversation.presenter = nil
        conversation = makeConversation()
        conversation.presenter = self
        ConciergeActiveConversation.activate(conversation)
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
        renewConversationIfSessionExpired()
        return conversation.deliverHandoff(routingHint: routingHint, xdmFields: xdmFields,
                                    localMessage: localMessage, completion: completion)
    }

    /// Removes the row `turnId` streams into, if it is still there. Looked up by id: the transcript
    /// shifts under a turn as cards and suggestions are appended.
    private func discardPlaceholder(_ turnId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == turnId }) else { return }
        messages.remove(at: index)
    }

    #if DEBUG
    /// Test seam: renders a given chat state without running a real turn.
    ///
    /// Production has exactly one writer of `chatState` - `conversationDidChangeBusy` - which is the point of
    /// the property being `private(set)`. View snapshots still need to draw a state directly, and
    /// this makes that an explicit, test-only exception rather than a hole in the invariant.
    func setChatStateForTesting(_ state: ChatState) {
        chatState = state
    }
    #endif

    /// Abandons the turn in flight, if any, returning the chat to idle.
    ///
    /// Replaces a direct `chatState = .idle` write from the view layer. Forcing the state flag
    /// alone left the turn running: it went on streaming into a transcript the composer was now
    /// live against, and its caller was never told. Ending the turn properly reports it, removes
    /// its placeholder and releases the request.
    ///
    /// Discarding the placeholder is deliberate for *both* turn kinds, not just `.handoff`. A
    /// typed turn's placeholder may already hold partial text, and that text is an answer to a
    /// question the chat is no longer in a position to finish - leaving a truncated reply behind
    /// with no indication it was cut short reads as a complete answer. Note this is currently
    /// unreachable: the only caller is `ChatView`'s `onToggleMode`, and `ChatTopBar` never invokes
    /// it because its `body` doesn't render the toggle.
    func abandonActiveTurn() {
        conversation.abandonActiveTurn()
    }

    func endConversationForIdentityReset() {
        endedForIdentityReset = true
        nativeCards.removeAll()
        conversation.endForIdentityReset()
        speechController.stopSpeaking()
        speechController.endCapture { _, _ in }
        inputController.apply(.reset)
        messages = []
        userMessageToScrollId = nil
        showPermissionDialog = false
        audioLevel = 0
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
        guard identityReady, !welcomeMessagesLoaded && messages.isEmpty else { return }
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
        guard identityReady else {
            Log.warning(label: LOG_TAG, "Feedback rejected because identity reset ended the conversation.")
            return
        }
        guard let messageId = messageId, let index = messages.firstIndex(where: { $0.id == messageId }) else {
            Log.debug(label: LOG_TAG, "Unable to send feedback, the message was not retrievable from the chat.")
            return
        }

        guard configuration != nil else {
            Log.debug(label: LOG_TAG, "Unable to send feedback, configuration is not available.")
            return
        }

        guard let messagePayload = messages[index].payload else {
            Log.debug(label: LOG_TAG, "Unable to send feedback, message payload is not available.")
            return
        }
        messages[index].feedbackSentiment = feedbackPayload.sentiment
        conversation.submitFeedback(conversationId: messagePayload.conversationId,
                                    interactionId: messagePayload.interactionId,
                                    sentiment: feedbackPayload.sentiment,
                                    reasons: feedbackPayload.selectedOptions,
                                    notes: feedbackPayload.notes)
    }

    // MARK: - Tracking

    func trackChatOpened() {
        conversation.track(.opened)
    }

    func trackChatClosed() {
        conversation.track(.closed)
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
        conversation.track(.ctaClicked(label: label, url: url))
    }

    func trackCardClicked(cardData: ProductCardData) {
        ConciergeTrackingEvent.cardClickedEvents(name: cardData.title,
                                                 description: cardData.subtitle,
                                                 pageURL: cardData.destinationURL?.absoluteString,
                                                 price: cardData.price,
                                                 badge: cardData.badge)
            .forEach(dispatchTrackingEvent)
    }

    func trackLinkClicked(url: String, origin: String) {
        dispatchTrackingEvent(.linkClicked(url: url, origin: origin))
    }

    private func dispatchTrackingEvent(_ trackingEvent: ConciergeTrackingEvent) {
        conversation.report(trackingEvent)
    }

    // MARK: - Private Methods

    private func configureSpeech() {
        speechController.configureForStreaming { [weak self] text in
            Task { @MainActor in
                guard let self, self.identityReady else { return }
                self.inputController.apply(.streamingPartial(text))
            }
        }
    }

    /// Applies `edit` to the row `turnId` streams into and returns the result, or `nil` when that
    /// row is no longer in the transcript. Looked up by id rather than a captured index.
    @discardableResult
    private func updatePlaceholder(_ turnId: UUID, _ edit: (inout Message) -> Void) -> Message? {
        guard let index = messages.firstIndex(where: { $0.id == turnId }) else { return nil }
        var current = messages[index]
        edit(&current)
        messages[index] = current
        return current
    }

    private func appendElementRows(_ plan: ResponseElementPlan, payload: ConversationPayload, sessionId: String?,
                                   promptSuggestions: [String]) {
        let newMessages = plan.makeMessages(nativeCards: nativeCards, payload: payload, sessionId: sessionId,
                                            promptSuggestions: promptSuggestions)
        if !newMessages.isEmpty { messages.append(contentsOf: newMessages) }
    }

    #if DEBUG
    func renderElementsForTesting(_ elements: [MultimodalElement], turnId: UUID,
                                  payload: ConversationPayload, sessionId: String? = nil,
                                  promptSuggestions: [String] = []) {
        let plan = ResponseElementResolver.resolve(elements, turnId: turnId, nativeCards: nativeCards)
        appendElementRows(plan, payload: payload, sessionId: sessionId, promptSuggestions: promptSuggestions)
        if let event = plan.cardsRenderedEvent { dispatchTrackingEvent(event) }
    }
    #endif
}

// MARK: - Drawing the conversation

extension ChatController: ConciergeConversationPresenter {
    func conversationDidChangeBusy(_ busy: Bool) {
        chatState = busy ? .processing : .idle
        nativeCards.setBusy(busy)
    }

    func conversationDidAppendUserMessage(_ text: String) -> UUID {
        let message = Message(template: .basic(isUserMessage: true), messageBody: text)
        messages.append(message)
        scrollToTop(messageId: message.id)
        return message.id
    }

    func conversationWillStartTurn() -> UUID {
        let placeholder = Message(template: .basic(isUserMessage: false), messageBody: "")
        messages.append(placeholder)
        return placeholder.id
    }

    func conversationDidAppendLocalMessage(_ text: String) -> UUID {
        let message = Message(template: .basic(isUserMessage: false), messageBody: text)
        messages.append(message)
        return message.id
    }

    /// A handoff is triggered from app UI rather than the composer, so scroll its first row to the top.
    func conversationDidStartHandoff(anchorId: UUID) {
        scrollToTop(messageId: anchorId)
    }

    func conversationDidUpdate(turnId: UUID, text: String, payload: ConversationPayload) {
        Log.trace(label: LOG_TAG, "Assembled text (len=\(text.count), state=\(payload.state ?? "n/a"))")
        updatePlaceholder(turnId) { current in
            current.messageBody = text
            current.payload = payload
        }
    }

    func conversationDidDiscard(turnId: UUID) {
        discardPlaceholder(turnId)
    }

    /// A failed turn is a finished one: show the failure and return to idle.
    func conversationDidFail() {
        messages.append(Message(template: .basic(isUserMessage: false), messageBody: networkErrorMessage))
    }

    /// Nothing in the response could be shown, but its suggestions still offer a next step.
    func conversationDidReceiveEmptyResponse(promptSuggestions: [String]) {
        let errorMessage = Message(template: .basic(isUserMessage: false), messageBody: "Sorry, I wasn't able to get a response from the Concierge Service. \n\nPlease try again later.")
        messages.append(contentsOf: [errorMessage] + promptSuggestions.map {
            Message(template: .promptSuggestion(text: $0))
        })
    }

    func conversationPlan(for elements: [MultimodalElement], turnId: UUID, allowsNativeCards: Bool) -> ConciergeRenderPlan {
        ResponseElementResolver.resolve(elements, turnId: turnId, nativeCards: nativeCards,
                                        allowsNativeCards: allowsNativeCards)
    }

    func conversationDidComplete(turnId: UUID, turn: ConciergeTurn) -> Bool {
        let completed = updatePlaceholder(turnId) { current in
            current.messageBody = turn.text
            current.shouldSpeakMessage = !turn.text.isEmpty
            if !turn.sources.isEmpty {
                Log.trace(label: LOG_TAG, "Using sources: count=\(turn.sources.count)")
                current.sources = turn.sources
            }
            if !turn.linkHints.isEmpty {
                Log.trace(label: LOG_TAG, "Using linkHints: count=\(turn.linkHints.count)")
                current.linkHints = turn.linkHints
            }
            current.feedbackEligible = current.payload?.response?.feedback?.eligible ?? false
            current.isStreamComplete = true
        }
        return completed?.payload != nil
    }

    func conversationRender(_ plan: ConciergeRenderPlan, payload: ConversationPayload, sessionId: String?,
                            promptSuggestions: [String]) {
        guard let plan = plan as? ResponseElementPlan else { return }
        appendElementRows(plan, payload: payload, sessionId: sessionId, promptSuggestions: promptSuggestions)
    }
}

// MARK: - Array Safe Access Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
