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

import AEPCore
import AEPServices
import Foundation

/// The transport-facing half of a conversation: configuration, session, auth token, XDM context,
/// the SSE stream and feedback. Holds no transcript and no turn rules; `ConciergeConversation`
/// owns those, for the SDK's chat UI and headless apps alike.
final class ConciergeConversationCore {
    private let LOG_TAG = "ConciergeConversationCore"

    let configuration: ConciergeConfiguration
    let transport: ConciergeChatService
    /// The backend session this conversation runs on, fixed at creation. A conversation never moves
    /// to another session; when this one expires the conversation closes.
    let sessionId: String
    /// Whether `sessionId` came from `SessionManager` and so can expire. A configuration that names
    /// its own session (tests) never does.
    private let tracksPersistedSession: Bool
    private let identityGeneration: Int
    private let lock = NSLock()
    private var ended = false
    /// Where feedback events are reported.
    let dispatch: (Event) -> Void

    init(configuration: ConciergeConfiguration, transport: ConciergeChatService, identityGeneration: Int,
         dispatch: @escaping (Event) -> Void = { MobileCore.dispatch(event: $0) }) {
        self.configuration = configuration
        self.transport = transport
        self.sessionId = transport.resolveSessionID()
        self.tracksPersistedSession = !configuration.hasExplicitSessionId
        self.identityGeneration = identityGeneration
        self.dispatch = dispatch
    }

    convenience init(configuration: ConciergeConfiguration,
                     urlSessionConfiguration: URLSessionConfiguration = .default,
                     buffersSSEFrames: Bool = false,
                     identityGeneration: Int? = nil,
                     dispatch: @escaping (Event) -> Void = { MobileCore.dispatch(event: $0) }) {
        let generation = identityGeneration ?? ConciergeIdentityBoundary.shared.synchronized {
            ConciergeIdentityBoundary.shared.generation
        }
        self.init(configuration: configuration,
                  transport: ConciergeChatService(configuration: configuration, urlSessionConfiguration: urlSessionConfiguration,
                                                 buffersSSEFrames: buffersSSEFrames),
                  identityGeneration: generation,
                  dispatch: dispatch)
    }

    /// Whether the session has passed its TTL, or `SessionManager` has since moved to another one.
    var isSessionExpired: Bool {
        tracksPersistedSession && SessionManager.shared.currentSessionIdIfActive != sessionId
    }

    /// Whether an identity reset ended the conversation. An ended core sends nothing.
    var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended || !ConciergeIdentityBoundary.shared.admits(identityGeneration)
    }

    /// Cancels the request in flight, if any.
    func cancel() {
        transport.cancelActiveStream()
    }

    /// Cancels the request in flight and releases the transport. Feedback already sent finishes.
    func close() {
        transport.cancelActiveStream()
        transport.invalidate()
    }

    /// Sends end-user feedback for one agent response.
    ///
    /// `conversationId` and `interactionId` come from the response's `ConversationPayload`.
    /// Also dispatches the `feedbackSubmitted` tracking event.
    func sendFeedback(conversationId: String?,
                             interactionId: String?,
                             sentiment: FeedbackSentiment,
                             reasons: [String] = [],
                             notes: String = "") {
        guard !isEnded else {
            Log.warning(label: LOG_TAG, "Feedback rejected because identity reset ended the conversation.")
            return
        }
        let data = Self.feedbackEventData(configuration: configuration,
                                          conversationId: conversationId,
                                          interactionId: interactionId,
                                          sentiment: sentiment,
                                          reasons: reasons,
                                          notes: notes)
        dispatch(ConciergeTrackingEvent.feedbackSubmitted(conversationId: conversationId ?? "unknown",
                                                          interactionId: interactionId ?? "unknown",
                                                          feedbackType: sentiment == .positive ? "positive" : "negative",
                                                          selectedOptions: reasons,
                                                          notes: notes).toEvent())
        Task { [self] in
            let token = await ConciergeAuthTokenResolver.shared.resolveToken()
            ConciergeIdentityBoundary.shared.synchronized {
                guard !self.isEnded else { return }
                self.transport.sendFeedback(data: data, token: token)
            }
        }
    }

    // MARK: - Internal API (shared with the SDK chat UI)

    struct RequestContext {
        let sessionID: String
        let xdmFields: [String: Any]
    }

    /// Freezes the session and XDM context for one turn. Called before any asynchronous wait so the
    /// request carries the same snapshot the turn's `querySubmitted` event reported.
    func requestContext(sessionID: String? = nil,
                        heldXDMFields: [String: Any]? = nil,
                        extraXDMFields: [String: Any]? = nil) -> RequestContext {
        let resolvedSessionID = sessionID ?? sessionId
        var merged = heldXDMFields ?? ConciergeXDMContextStore.shared.snapshot(for: resolvedSessionID)
        if let extraXDMFields {
            merged = ConciergeXDMContextStore.merging(extraXDMFields, over: merged)
        }
        return RequestContext(sessionID: resolvedSessionID, xdmFields: merged)
    }

    /// Starts one streaming request with an already-resolved token.
    func stream(_ query: String,
                token: String?,
                context: RequestContext,
                onChunk: @escaping (ConversationPayload) -> Void,
                onComplete: @escaping (ConciergeError?) -> Void) {
        transport.streamChat(query, token: token,
                             extraXDMFields: context.xdmFields.isEmpty ? nil : context.xdmFields,
                             sessionID: context.sessionID,
                             onChunk: onChunk,
                             onComplete: onComplete)
    }

    /// Ends the conversation for an identity reset: cancels feedback in flight and tears down the
    /// transport, which also cancels a streaming turn (its stream finishes with an error).
    func endForIdentityReset() {
        lock.lock()
        ended = true
        lock.unlock()
        transport.endFeedbackForIdentityReset()
        transport.invalidateTransportForIdentityReset()
    }

    static func feedbackEventData(configuration: ConciergeConfiguration,
                                  conversationId: String?,
                                  interactionId: String?,
                                  sentiment: FeedbackSentiment,
                                  reasons: [String],
                                  notes: String) -> [String: Any] {
        typealias Keys = ConciergeConstants.Request.Keys
        typealias Values = ConciergeConstants.Request.Values
        return [
            Keys.XDM: [
                Keys.EVENT_TYPE: ConciergeConstants.Request.EventType.CONVERSATION_FEEDBACK,
                // Forward identityMap verbatim; falls back to an ECID-only map
                Keys.IDENTITY_MAP: configuration.identityMapPayload,
                Keys.CONVERSATION: [
                    Keys.Feedback.FEEDBACK: [
                        Keys.Feedback.SOURCE: Values.Feedback.END_USER,
                        Keys.Feedback.RAW: [
                            [
                                Keys.Feedback.TEXT: notes,
                                Keys.Feedback.PURPOSE: Values.Feedback.USER_INPUT
                            ]
                        ],
                        Keys.Feedback.RATING: [
                            Keys.Feedback.SCORE: sentiment == .positive ? 1 : 0,
                            Keys.Feedback.CLASSIFICATION: sentiment.thumbsValue(),
                            Keys.Feedback.REASONS: reasons
                        ]
                    ],
                    Keys.Feedback.CONVERSATION_ID: conversationId ?? "unknown",
                    Keys.Feedback.TURN_ID: interactionId ?? "unknown"
                ]
            ]
        ]
    }

}
