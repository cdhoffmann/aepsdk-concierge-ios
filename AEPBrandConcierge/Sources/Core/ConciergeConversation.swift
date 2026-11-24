/*
 Copyright 2026 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import AEPCore
import AEPServices
import Combine
import Foundation

/// A Brand Concierge conversation, for apps that render their own chat UI.
///
/// Obtain one with `Concierge.conversation(surfaces:)` and render `messages`; both it and `state`
/// are published, so a SwiftUI view can observe the conversation directly. The conversation owns
/// everything the SDK's chat UI does short of drawing: configuration, session, auth token
/// pass-through, XDM context, streaming, turn rules and analytics, feedback, and identity reset.
/// The SDK's chat UI is built on this same type.
///
/// One conversation is live at a time, and it runs on one backend session for its whole life.
/// Opening another conversation, or a new SDK chat UI session, closes this one (`.replaced`).
/// A data handoff sent with `Concierge.sendDataHandoff(...)` goes to the live conversation and shows
/// up in `messages` like any other response. One response runs at a time.
///
/// Once `.closed` - by `close()`, replacement, session expiry or an identity reset
/// (`MobileCore.resetIdentities()`) - the conversation sends nothing more; create a new one.
@MainActor
public final class ConciergeConversation: ObservableObject {
    private let LOG_TAG = "ConciergeConversation"

    /// The transcript, oldest first. Agent messages are added when their first content arrives.
    @Published public private(set) var messages: [ConciergeMessage] = []
    @Published public private(set) var state: ConciergeConversationState = .idle

    /// The configuration resolved for the surfaces this conversation was created with.
    public var configuration: ConciergeConfiguration { core.configuration }

    /// The backend session this conversation runs on. It never changes; when the session expires
    /// the conversation closes with `.sessionExpired`.
    public var sessionId: String { core.sessionId }

    // MARK: - Internal

    let core: ConciergeConversationCore
    /// The SDK's chat UI, when it is the one rendering this conversation.
    weak var presenter: ConciergeConversationPresenter?
    private(set) var lastTurnSessionID: String?
    /// The latest conversation ID the service reported.
    private(set) var conversationId: String?
    var isResponding: Bool { activeTurn != nil }

    private let dispatch: (Event) -> Void
    private let appState: ConciergeAppState
    private let handoffLimits: HandoffLimits
    /// Longest wait after which a background-interrupted turn is no longer resent.
    private let backgroundRecoveryMaxAge: TimeInterval
    private var endedForIdentityReset = false
    private var openedAt: Date?
    private var feedbackIds: [String: (conversationId: String?, interactionId: String?)] = [:]
    /// The typed message whose turn failed last, for `retry()`.
    private var retryableQuery: String?
    private var cancellables = Set<AnyCancellable>()
    private var foregroundRetryCancellable: AnyCancellable?

    /// The turn in flight, or `nil` when idle. At most one exists: `ConciergeChatService` keeps a
    /// single `dataTask`/handler pair per instance, so a second concurrent turn would strand the
    /// first one's completion. The only writer of `.responding`.
    private var activeTurn: ChatTurn? {
        didSet {
            if activeTurn != nil { state = .responding }
            presenter?.conversationDidChangeBusy(activeTurn != nil)
        }
    }

    /// Whether the conversation can still send: not closed, and not ended by an identity reset.
    var isLive: Bool {
        !endedForIdentityReset && !state.isClosed && !core.isEnded
    }

    init(core: ConciergeConversationCore,
         dispatch: @escaping (Event) -> Void,
         appState: ConciergeAppState = .shared,
         handoffLimits: HandoffLimits = .standard,
         backgroundRecoveryMaxAge: TimeInterval = ConciergeConstants.Session.TTL_SECONDS) {
        self.core = core
        self.dispatch = dispatch
        self.appState = appState
        self.handoffLimits = handoffLimits
        self.backgroundRecoveryMaxAge = backgroundRecoveryMaxAge
        appState.statePublisher
            .sink { [weak self] state in
                guard let self = self, state == .background else { return }
                self.activeTurn?.noteAppBackgrounded()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Sends `text` as the user's message and streams the agent's response into `messages`.
    ///
    /// The auth token registered with `Concierge.setAuthTokenProvider` and the context set with
    /// `Concierge.updateXDMContext` are attached automatically. Turn analytics are reported for you.
    @discardableResult
    public func send(_ text: String) -> ConciergeSendResult {
        ConciergeIdentityBoundary.shared.synchronized {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { return .blank }
            if let refusal = admissionRefusal() { return refusal }
            startUserTurn(message)
            return .accepted
        }
    }

    /// Resends the typed message whose response failed, without adding it to `messages` again.
    /// Only valid while `state` is `.failed` after a typed message.
    @discardableResult
    public func retry() -> ConciergeSendResult {
        ConciergeIdentityBoundary.shared.synchronized {
            if let refusal = admissionRefusal() { return refusal }
            guard case .failed = state, let query = retryableQuery else { return .nothingToRetry }
            startQueryTurn(query)
            return .accepted
        }
    }

    /// Stops the response in progress. Text received so far stays in `messages`. A data handoff
    /// stopped this way reports a delivery failure to its sender.
    public func cancel() {
        guard let turn = activeTurn else { return }
        turn.resolve(.unknown)
        finishStreaming(turn)
        endTurn(turn)
        core.cancel()
    }

    /// Sends end-user feedback on the agent message with `messageId`. The message must have
    /// `feedbackEnabled` set. Reports the `feedbackSubmitted` event.
    public func sendFeedback(messageId: String, _ feedback: ConciergeFeedback) {
        guard isLive,
              let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].feedbackEnabled,
              let ids = feedbackIds[messageId] else {
            Log.warning(label: LOG_TAG, "Feedback ignored: no feedback-enabled message with ID '\(messageId)'.")
            return
        }
        messages[index].feedback = feedback.sentiment
        submitFeedback(conversationId: ids.conversationId, interactionId: ids.interactionId,
                       sentiment: feedback.sentiment, reasons: feedback.categories, notes: feedback.notes)
    }

    /// Reports a user interaction. See `ConciergeInteraction`.
    public func track(_ interaction: ConciergeInteraction) {
        guard !state.isClosed else { return }
        typealias Origin = ConciergeConstants.TrackingEvent.LinkClickOrigin
        let events: [ConciergeTrackingEvent]
        switch interaction {
        case .opened:
            let now = Date()
            openedAt = now
            events = [.chatOpened(epochTime: Self.epochMillis(now))]
        case .closed:
            let now = Date()
            let duration = openedAt.map { Int64(now.timeIntervalSince($0) * 1000) } ?? 0
            openedAt = nil
            events = [.chatClosed(epochTime: Self.epochMillis(now), durationMillis: duration)]
        case .promptSuggestionClicked(let suggestion):
            events = [.promptSuggestionClicked(suggestion: suggestion)]
        case .ctaClicked(let label, let url):
            events = ConciergeTrackingEvent.ctaButtonClickedEvents(label: label, url: url)
        case .productCardClicked(let card):
            events = ConciergeTrackingEvent.cardClickedEvents(name: card.productName,
                                                              description: card.productDescription,
                                                              pageURL: card.productPageURL,
                                                              price: card.productPrice,
                                                              badge: card.productBadge)
        case .productActionClicked(let card, let action):
            events = ConciergeTrackingEvent.cardClickedEvents(name: card.productName ?? action.text,
                                                              description: nil, pageURL: action.url,
                                                              price: nil, badge: nil)
        case .sourceClicked(let source):
            events = [.linkClicked(url: source.url, origin: Origin.CITATION)]
        case .linkClicked(let url):
            events = [.linkClicked(url: url, origin: Origin.INLINE)]
        case .linkHintClicked(let hint):
            events = [.linkClicked(url: hint.href, origin: Origin.LINK_HINT)]
        }
        events.forEach(report)
    }

    /// Stops any response in progress and releases the conversation. `state` becomes
    /// `.closed(.closedByApp)`.
    public func close() {
        close(reason: .closedByApp)
    }

    // MARK: - Internal API (shared with the SDK chat UI)

    func close(reason: ConciergeCloseReason) {
        guard !state.isClosed else { return }
        cancel()
        foregroundRetryCancellable?.cancel()
        foregroundRetryCancellable = nil
        retryableQuery = nil
        state = .closed(reason)
        core.close()
        ConciergeActiveConversation.deactivate(self)
    }

    /// Closes the conversation with `.sessionExpired` if its session has expired. Returns whether
    /// the conversation is closed.
    @discardableResult
    func closeIfSessionExpired() -> Bool {
        if !state.isClosed, core.isSessionExpired {
            Log.debug(label: LOG_TAG, "Closing the conversation because its session expired.")
            close(reason: .sessionExpired)
        }
        return state.isClosed
    }

    /// Why `send(_:)` or `retry()` can't start a turn now, or `nil` if it can.
    private func admissionRefusal() -> ConciergeSendResult? {
        if closeIfSessionExpired() { return .closed }
        if !isLive { return .resetPending }
        if activeTurn != nil { return .inProgress }
        return nil
    }

    /// Starts a typed turn for `text`, which the caller has already validated.
    private func startUserTurn(_ text: String) {
        let id = presenter?.conversationDidAppendUserMessage(text) ?? UUID()
        messages.append(ConciergeMessage(id: id.uuidString, role: .user, text: text))
        startQueryTurn(text)
    }

    private func startQueryTurn(_ text: String) {
        retryableQuery = nil
        ConciergeActiveConversation.markUsed(self)
        // Read synchronously so the request carries the exact snapshot this event reports.
        let sessionID = core.sessionId
        let xdmContext = ConciergeXDMContextStore.shared.snapshot(for: sessionID)
        report(.querySubmitted(query: text, xdmFields: xdmContext))
        startTurn(for: text, heldXDMFields: xdmContext, sessionID: sessionID)
    }

    /// Delivers an app-originated data handoff (ex: a checkout outcome). The routing hint is never
    /// shown; only `localMessage` and the eventual reply are.
    ///
    /// Returns `false` without starting anything when a turn is already in flight.
    func deliverHandoff(routingHint: String,
                        xdmFields: [String: Any],
                        localMessage: String? = nil,
                        completion: ((ConciergeError?) -> Void)? = nil) -> Bool {
        ConciergeIdentityBoundary.shared.synchronized {
            guard isLive else {
                Log.warning(label: LOG_TAG, "Data handoff rejected because identity reset is pending.")
                completion?(.unknown)
                return true
            }
            guard activeTurn == nil else {
                Log.warning(label: LOG_TAG, "Data handoff ignored. A Concierge turn is already in progress.")
                return false
            }

            var anchorId: UUID?
            if let localMessage, !localMessage.isEmpty {
                let id = presenter?.conversationDidAppendLocalMessage(localMessage) ?? UUID()
                messages.append(ConciergeMessage(id: id.uuidString, role: .app, text: localMessage))
                anchorId = id
            }
            let turn = startTurn(for: routingHint, extraXDMFields: xdmFields,
                                 kind: .handoff(handoffLimits), completion: completion)
            presenter?.conversationDidStartHandoff(anchorId: anchorId ?? turn.placeholderId)
            return true
        }
    }

    /// Ends the turn in flight and removes its partial response. Used by the SDK UI's stop control.
    func abandonActiveTurn() {
        guard let turn = activeTurn else { return }
        turn.resolve(.unknown)
        discardResponse(of: turn)
        endTurn(turn)
        core.cancel()
    }

    func submitFeedback(conversationId: String?, interactionId: String?, sentiment: FeedbackSentiment,
                        reasons: [String], notes: String) {
        core.sendFeedback(conversationId: conversationId, interactionId: interactionId,
                          sentiment: sentiment, reasons: reasons, notes: notes)
    }

    /// Reports an SDK event through this conversation's dispatcher.
    func report(_ trackingEvent: ConciergeTrackingEvent) {
        let event = trackingEvent.toEvent()
        Log.debug(label: LOG_TAG, "Dispatching tracking event - name: \(event.name), type: \(event.type), source: \(event.source), data: \(event.data ?? [:])")
        dispatch(event)
    }

    func endForIdentityReset() {
        guard !endedForIdentityReset else { return }
        endedForIdentityReset = true
        abandonActiveTurn()
        core.endForIdentityReset()
        foregroundRetryCancellable?.cancel()
        foregroundRetryCancellable = nil
        messages = []
        feedbackIds = [:]
        retryableQuery = nil
        lastTurnSessionID = nil
        conversationId = nil
        state = .closed(.identityReset)
        ConciergeActiveConversation.deactivate(self)
    }

    // MARK: - Turn engine

    /// Starts a turn: sends the query and streams the reply into the transcript. Returns the turn,
    /// which becomes `activeTurn`. `kind` decides whether failures render and whether the turn is
    /// bounded; see `TurnKind`.
    @discardableResult
    private func startTurn(for query: String,
                           heldXDMFields: [String: Any]? = nil,
                           extraXDMFields: [String: Any]? = nil,
                           sessionID: String? = nil,
                           kind: TurnKind = .typed,
                           allowsBackgroundRecovery: Bool = true,
                           completion: ((ConciergeError?) -> Void)? = nil) -> ChatTurn {
        let turn = ChatTurn(placeholderId: presenter?.conversationWillStartTurn() ?? UUID(),
                            kind: kind,
                            allowsBackgroundRecovery: allowsBackgroundRecovery,
                            outcome: completion)
        if appState.state == .background {
            turn.noteAppBackgrounded()
        }
        activeTurn = turn

        // Armed from submission, so it also bounds the auth-token wait below.
        turn.armCeiling { [weak self] interval in
            self?.cap(turn, after: interval, reason: "exceeded its wall-clock cap")
        }

        // Freeze the context before the token wait, so the request carries the same snapshot a
        // typed turn already reported in its querySubmitted event.
        let requestContext = core.requestContext(sessionID: sessionID, heldXDMFields: heldXDMFields,
                                                 extraXDMFields: extraXDMFields)
        lastTurnSessionID = requestContext.sessionID

        var assembled = ConciergeTurn()
        var completedElements: [MultimodalElement] = []
        var lastPayload: ConversationPayload?
        let attemptStartedAt = Date()
        let callbackSequencer = MainActorCallbackSequencer()

        // `self` and `turn` are held strongly on purpose: an app that drops its reference
        // mid-turn has not cancelled the turn, and `turn` owns the caller's completion.
        Task { [self] in
            let token = await ConciergeAuthTokenResolver.shared.resolveToken()

            ConciergeIdentityBoundary.shared.synchronized {
                // A deadline may have fired while the token resolved; `resolve` keeps that outcome.
                guard self.isLive, self.activeTurn === turn else {
                    Log.debug(label: self.LOG_TAG, "Turn abandoned before it reached the service; not sending.")
                    turn.resolve(.unknown)
                    return
                }
                turn.armNoResponseCap { [weak self] interval in
                    self?.cap(turn, after: interval, reason: "produced no response")
                }
                self.core.stream(query, token: token, context: requestContext, onChunk: { payload in
                    callbackSequencer.enqueue { [weak self] in
                        guard let self = self, self.isLive, self.activeTurn === turn else { return }

                        // Any chunk, including a heartbeat, proves the backend is alive. Whether
                        // there is something to *show* is the separate `responseStarted` gate below.
                        turn.noteResponseStarted()
                        if payload.isCompleted {
                            turn.noteResponseCompleted()
                            completedElements = payload.response?.multimodalElements?.elements ?? []
                        }
                        #if DEBUG
                        if let description = payload.response?.debugLogDescription {
                            Log.debug(label: self.LOG_TAG, "SSE chunk (state=\(payload.state ?? "n/a")): \(description)")
                        } else {
                            Log.debug(label: self.LOG_TAG, "SSE chunk: state=\(payload.state ?? "n/a") (no response)")
                        }
                        #endif

                        // Exactly once per turn, on the first chunk with text or elements.
                        if assembled.apply(payload) {
                            self.report(.responseStarted(conversationId: assembled.conversationId ?? "unknown",
                                                         interactionId: assembled.interactionId ?? "unknown"))
                        }
                        if let id = assembled.conversationId { self.conversationId = id }
                        if payload.response != nil, payload.isInProgress || payload.isCompleted {
                            lastPayload = payload
                            self.presenter?.conversationDidUpdate(turnId: turn.placeholderId,
                                                                  text: assembled.text, payload: payload)
                            if assembled.hasVisibleContent {
                                self.upsertAgentMessage(turn, text: assembled.text, isStreaming: true)
                            }
                        }
                    }
                }, onComplete: { error in
                    callbackSequencer.enqueue { [weak self] in
                        // A turn a deadline ended has already reported and unwound.
                        guard !turn.isResolved else { return }
                        guard let self = self, self.isLive, self.activeTurn === turn else {
                            turn.resolve(error ?? .unknown)
                            return
                        }

                        // Closes the race where the stream fails after the background notification
                        // but before the Combine observer receives it.
                        if self.appState.state == .background {
                            turn.noteAppBackgrounded()
                        }

                        // A completed response is authoritative even if the transport errors as it closes.
                        let effectiveError = turn.hasCompletedResponse ? nil : error
                        if let effectiveError, turn.reserveBackgroundRecovery(for: effectiveError) {
                            self.retryAfterForeground(turn, RecoveryRequest(query: query,
                                                                            xdmFields: requestContext.xdmFields,
                                                                            sessionID: requestContext.sessionID,
                                                                            error: effectiveError,
                                                                            attemptStartedAt: attemptStartedAt))
                            return
                        }

                        // The caller hears back on every path out of here; `resolve` is idempotent.
                        var outcome: ConciergeError? = effectiveError
                        defer { turn.resolve(outcome) }

                        if let error = effectiveError {
                            if !turn.allowsBackgroundRecovery {
                                Log.warning(label: self.LOG_TAG, "Background recovery resend failed; no further resend will be attempted.")
                            } else if turn.hasOverlappedBackground {
                                Log.debug(label: self.LOG_TAG, "Background-overlapped turn failure is not eligible for automatic recovery.")
                            }
                            Log.error(label: self.LOG_TAG, "Streaming error: \(error)")
                            self.report(.errorOccurred(errorMessage: error.localizedDescription))
                            self.discardResponse(of: turn)
                            if turn.rendersFailures { self.presenter?.conversationDidFail() }
                            self.endTurn(turn, failure: error, query: query)
                            return
                        }

                        let elements = completedElements.isEmpty ? assembled.elements : completedElements
                        let plan: ConciergeRenderPlan = self.presenter?.conversationPlan(
                            for: elements, turnId: turn.placeholderId,
                            allowsNativeCards: !completedElements.isEmpty) ?? ConciergeElementPlan(elements)
                        guard !assembled.text.isEmpty || plan.hasRenderableElements else {
                            outcome = .invalidResponseData
                            self.discardResponse(of: turn)
                            if turn.rendersFailures {
                                Log.warning(label: self.LOG_TAG, "Completed response had nothing renderable; showing the error message.")
                                self.report(.errorOccurred(errorMessage: ConciergeError.invalidResponseData.localizedDescription))
                                self.presenter?.conversationDidReceiveEmptyResponse(promptSuggestions: assembled.promptSuggestions)
                            }
                            self.endTurn(turn, failure: .invalidResponseData, query: query)
                            return
                        }

                        let presented = self.presenter?.conversationDidComplete(turnId: turn.placeholderId,
                                                                                turn: assembled) ?? true
                        guard presented, let completedPayload = lastPayload else {
                            Log.warning(label: self.LOG_TAG, "responseCompleted skipped: the turn's message is no longer in the transcript")
                            self.endTurn(turn)
                            return
                        }
                        // A cards-only response has nothing for the SDK UI's text bubble.
                        if assembled.text.isEmpty {
                            self.presenter?.conversationDidDiscard(turnId: turn.placeholderId)
                        }
                        self.completeAgentMessage(turn, assembled: assembled, elements: elements)
                        self.report(.responseCompleted(conversationId: completedPayload.conversationId ?? "unknown",
                                                       interactionId: completedPayload.interactionId ?? "unknown"))
                        self.presenter?.conversationRender(plan, payload: completedPayload,
                                                           sessionId: requestContext.sessionID,
                                                           promptSuggestions: assembled.promptSuggestions)
                        if let event = plan.cardsRenderedEvent { self.report(event) }
                        self.endTurn(turn)
                    }
                })
            }
        }

        return turn
    }

    /// Ends `turn` because one of its deadlines elapsed.
    ///
    /// Unwinds directly rather than relying on cancellation: until the token resolves there is no
    /// request to cancel, and dropping the turn drops the late callbacks that would revive it.
    private func cap(_ turn: ChatTurn, after interval: TimeInterval, reason: String) {
        guard activeTurn === turn else { return }
        Log.warning(label: LOG_TAG, "Data handoff turn \(reason).")
        turn.resolve(.timeout(Int(interval)))
        discardResponse(of: turn)
        endTurn(turn, failure: .timeout(Int(interval)))
        core.cancel()
    }

    private func retryAfterForeground(_ turn: ChatTurn, _ request: RecoveryRequest) {
        discardResponse(of: turn)
        guard appState.state == .background else {
            Log.debug(label: LOG_TAG, "Background recovery scheduled while app is foregrounded; starting resend now.")
            startRecovery(turn, request)
            return
        }

        Log.debug(label: LOG_TAG, "Background recovery scheduled; waiting for app foreground before resending.")
        foregroundRetryCancellable?.cancel()
        foregroundRetryCancellable = appState.statePublisher
            .filter { $0 == .foreground }
            .prefix(1)
            .sink { [weak self, weak turn] _ in
                Task { @MainActor in
                    guard let self = self, let turn = turn else { return }
                    self.startRecovery(turn, request)
                }
            }
    }

    private func startRecovery(_ turn: ChatTurn, _ request: RecoveryRequest) {
        guard isLive, activeTurn === turn, !turn.isResolved else { return }
        foregroundRetryCancellable?.cancel()
        foregroundRetryCancellable = nil

        // Past the session TTL the backend session has expired and the user has likely moved on.
        guard Date().timeIntervalSince(request.attemptStartedAt) < backgroundRecoveryMaxAge else {
            Log.warning(label: LOG_TAG, "Background recovery skipped because the session expired while waiting.")
            report(.errorOccurred(errorMessage: request.error.localizedDescription))
            presenter?.conversationDidFail()
            turn.resolve(request.error)
            endTurn(turn, failure: request.error, query: request.query)
            return
        }

        Log.debug(label: LOG_TAG, "Resending one background-interrupted typed chat turn.")
        turn.resolve(nil)
        // A new request with its own interaction ID, so it reports its own responseStarted/Completed.
        startTurn(for: request.query, heldXDMFields: request.xdmFields, sessionID: request.sessionID,
                  kind: .typed, allowsBackgroundRecovery: false)
    }

    /// Releases `turn` if it is still the live one. Guarded by identity so a superseded turn's late
    /// callback cannot end whichever turn is running now. A failed typed turn's `query` is kept
    /// for `retry()`.
    private func endTurn(_ turn: ChatTurn, failure: ConciergeError? = nil, query: String? = nil) {
        guard activeTurn === turn else { return }
        if foregroundRetryCancellable != nil {
            Log.debug(label: LOG_TAG, "Cancelling pending background recovery because the chat turn ended.")
        }
        foregroundRetryCancellable?.cancel()
        foregroundRetryCancellable = nil
        activeTurn = nil
        guard !state.isClosed else { return }
        if let failure {
            if case .typed = turn.kind { retryableQuery = query }
            state = .failed(failure)
        } else {
            state = .idle
        }
    }

    // MARK: - Transcript

    /// Removes `turn`'s response from the transcript, in this conversation and in the SDK UI.
    private func discardResponse(of turn: ChatTurn) {
        presenter?.conversationDidDiscard(turnId: turn.placeholderId)
        messages.removeAll { $0.id == turn.placeholderId.uuidString }
        feedbackIds.removeValue(forKey: turn.placeholderId.uuidString)
    }

    private func finishStreaming(_ turn: ChatTurn) {
        guard let index = messages.firstIndex(where: { $0.id == turn.placeholderId.uuidString }) else { return }
        messages[index].isStreaming = false
    }

    private func upsertAgentMessage(_ turn: ChatTurn, text: String, isStreaming: Bool) {
        let id = turn.placeholderId.uuidString
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
            messages[index].isStreaming = isStreaming
        } else {
            messages.append(ConciergeMessage(id: id, role: .agent, text: text, isStreaming: isStreaming))
        }
    }

    private func completeAgentMessage(_ turn: ChatTurn, assembled: ConciergeTurn, elements: [MultimodalElement]) {
        upsertAgentMessage(turn, text: assembled.text, isStreaming: false)
        let id = turn.placeholderId.uuidString
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].elements = elements.map(ConciergeElement.init)
        messages[index].sources = assembled.sources
        messages[index].linkHints = assembled.linkHints
        messages[index].promptSuggestions = assembled.promptSuggestions
        messages[index].feedbackEnabled = assembled.feedbackEligible
        if assembled.feedbackEligible {
            feedbackIds[id] = (assembled.conversationId, assembled.interactionId)
        }
    }

    private static func epochMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}

// MARK: - SDK chat UI hooks

/// What the SDK's chat UI needs to know to draw a conversation. A headless conversation has no
/// presenter; its `messages` are the whole picture.
@MainActor
protocol ConciergeConversationPresenter: AnyObject {
    func conversationDidChangeBusy(_ busy: Bool)
    /// The user's message was accepted and is about to be sent. Returns its row ID.
    func conversationDidAppendUserMessage(_ text: String) -> UUID
    /// A turn is starting. Returns the ID of the row its response streams into.
    func conversationWillStartTurn() -> UUID
    /// A handoff's `localMessage` was added. Returns its row ID.
    func conversationDidAppendLocalMessage(_ text: String) -> UUID
    func conversationDidStartHandoff(anchorId: UUID)
    func conversationDidUpdate(turnId: UUID, text: String, payload: ConversationPayload)
    func conversationDidDiscard(turnId: UUID)
    /// A turn that renders failures failed.
    func conversationDidFail()
    /// A typed turn completed with nothing to show.
    func conversationDidReceiveEmptyResponse(promptSuggestions: [String])
    /// Decides which elements the UI can show. Whether a response is empty depends on it.
    func conversationPlan(for elements: [MultimodalElement], turnId: UUID, allowsNativeCards: Bool) -> ConciergeRenderPlan
    /// Finalizes the turn's row. Returns `false` if the row is no longer in the transcript.
    func conversationDidComplete(turnId: UUID, turn: ConciergeTurn) -> Bool
    func conversationRender(_ plan: ConciergeRenderPlan, payload: ConversationPayload, sessionId: String?,
                            promptSuggestions: [String])
}

/// The elements of one response that can be shown.
protocol ConciergeRenderPlan {
    var hasRenderableElements: Bool { get }
    /// `cardsRendered` for the product cards shown, if any.
    var cardsRenderedEvent: ConciergeTrackingEvent? { get }
}

extension ResponseElementPlan: ConciergeRenderPlan {}

/// A headless conversation's plan: every classified element is shown by the app.
struct ConciergeElementPlan: ConciergeRenderPlan {
    let elements: [ConciergeElement]

    init(_ elements: [MultimodalElement]) {
        self.elements = elements.map(ConciergeElement.init)
    }

    var hasRenderableElements: Bool { elements.contains { $0.isRenderable } }

    var cardsRenderedEvent: ConciergeTrackingEvent? {
        ConciergeTrackingEvent.cardsRendered(for: elements.compactMap {
            if case .productCard(let card) = $0 { return card.raw }
            return nil
        })
    }
}

// MARK: - Live conversations

/// The live conversations - headless or the SDK chat UI's - that data handoffs and identity resets
/// go to. One per surface set: a new conversation on the same surfaces replaces the previous one,
/// while conversations on different surfaces coexist, all on the app's one backend session.
/// Weak: the app, or the chat UI's session, owns each conversation.
@MainActor
enum ConciergeActiveConversation {
    private static let LOG_TAG = "ConciergeActiveConversation"
    private final class WeakBox {
        weak var conversation: ConciergeConversation?
        init(_ conversation: ConciergeConversation) { self.conversation = conversation }
    }
    private static var slots: [Set<String>: WeakBox] = [:]
    private static weak var lastUsed: ConciergeConversation?

    /// Where a data handoff goes: the live conversation most recently opened or used.
    static var current: ConciergeConversation? {
        if let lastUsed, live.contains(where: { $0 === lastUsed }) { return lastUsed }
        return nil
    }

    static var live: [ConciergeConversation] {
        slots.values.compactMap(\.conversation)
    }

    /// Makes `conversation` the live one for its surfaces, closing the previous one on those
    /// surfaces with `.replaced`.
    static func activate(_ conversation: ConciergeConversation) {
        let key = Set(conversation.core.configuration.surfaces)
        if let previous = slots[key]?.conversation, previous !== conversation {
            Log.debug(label: LOG_TAG, "Closing the previous Concierge conversation on the same surfaces.")
            previous.close(reason: .replaced)
        }
        slots[key] = WeakBox(conversation)
        lastUsed = conversation
    }

    static func markUsed(_ conversation: ConciergeConversation) {
        if live.contains(where: { $0 === conversation }) { lastUsed = conversation }
    }

    static func deactivate(_ conversation: ConciergeConversation) {
        slots = slots.filter { $0.value.conversation != nil && $0.value.conversation !== conversation }
        if lastUsed === conversation { lastUsed = nil }
    }

    #if DEBUG
    static func resetForTesting() {
        slots = [:]
        lastUsed = nil
    }
    #endif
}

// MARK: - Helpers

/// Runs main-actor callbacks in the order they were enqueued.
final class MainActorCallbackSequencer {
    private let lock = NSLock()
    private var lastTask: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () -> Void) {
        lock.lock()
        let previousTask = lastTask
        lastTask = Task { @MainActor in
            await previousTask?.value
            operation()
        }
        lock.unlock()
    }
}

/// Everything needed to resend a background-interrupted typed turn once the app is foregrounded.
struct RecoveryRequest {
    let query: String
    let xdmFields: [String: Any]
    let sessionID: String
    /// The failure that triggered recovery; surfaced if the resend is skipped.
    let error: ConciergeError
    let attemptStartedAt: Date
}
