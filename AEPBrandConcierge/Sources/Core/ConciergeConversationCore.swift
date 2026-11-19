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

import AEPServices
import Foundation

/// UI-free access to a Brand Concierge conversation, for apps that render their own chat UI.
///
/// Obtain one with `Concierge.conversationCore(surfaces:)`. The core owns everything that has to
/// be identical between the SDK's chat UI and a custom one: configuration, session, auth token
/// pass-through, XDM context, the SSE transport and feedback events. It holds no transcript and
/// does no rendering - each `send` yields the raw `ConversationPayload` chunks from the service.
///
/// One turn runs at a time; `send` fails with `ConciergeError.turnInProgress` while another is
/// streaming. After an identity reset (`MobileCore.resetIdentities()`) the core is ended for good
/// and every call fails with `ConciergeError.conversationEnded`; request a new core.
///
/// The SDK's own chat UI is built on this type.
public final class ConciergeConversationCore {
    private let LOG_TAG = "ConciergeConversationCore"

    /// The configuration resolved for the surfaces this core was created with.
    public let configuration: ConciergeConfiguration

    let transport: ConciergeChatService
    private let identityGeneration: Int
    private let lock = NSLock()
    private var streaming = false
    private var ended = false

    init(configuration: ConciergeConfiguration, transport: ConciergeChatService, identityGeneration: Int) {
        self.configuration = configuration
        self.transport = transport
        self.identityGeneration = identityGeneration
    }

    convenience init(configuration: ConciergeConfiguration,
                     urlSessionConfiguration: URLSessionConfiguration = .default,
                     identityGeneration: Int? = nil) {
        let generation = identityGeneration ?? ConciergeIdentityBoundary.shared.synchronized {
            ConciergeIdentityBoundary.shared.generation
        }
        self.init(configuration: configuration,
                  transport: ConciergeChatService(configuration: configuration, urlSessionConfiguration: urlSessionConfiguration),
                  identityGeneration: generation)
    }

    // MARK: - Public API

    /// The backend session ID the next turn will use.
    public var sessionId: String { transport.resolveSessionID() }

    /// Whether the conversation was ended by an identity reset. An ended core rejects every call.
    public var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended || !ConciergeIdentityBoundary.shared.admits(identityGeneration)
    }

    /// Sends `query` and streams the service's response.
    ///
    /// The auth token registered with `Concierge.setAuthTokenProvider` and the context set with
    /// `Concierge.updateXDMContext` are attached automatically. `xdmFields` are merged over that
    /// context for this turn only.
    ///
    /// Chunks are yielded as received. `IN_PROGRESS` chunks carry a text delta; the final
    /// `COMPLETED` chunk carries the full message plus products, suggestions and sources.
    /// The stream finishes after the service closes the connection, or throws a `ConciergeError`.
    /// Cancelling the consuming task cancels the request.
    public func send(_ query: String, xdmFields: [String: Any]? = nil) -> AsyncThrowingStream<ConversationPayload, Error> {
        AsyncThrowingStream { continuation in
            if let rejection = beginStreaming() {
                continuation.finish(throwing: rejection)
                return
            }
            let context = requestContext(extraXDMFields: xdmFields)
            let task = Task { [self] in
                let token = await ConciergeAuthTokenResolver.shared.resolveToken()
                ConciergeIdentityBoundary.shared.synchronized {
                    guard !Task.isCancelled, !self.isEnded else {
                        self.endStreaming()
                        continuation.finish(throwing: self.isEnded ? ConciergeError.conversationEnded : CancellationError())
                        return
                    }
                    self.stream(query, token: token, context: context,
                                onChunk: { continuation.yield($0) },
                                onComplete: { error in
                                    self.endStreaming()
                                    if let error {
                                        continuation.finish(throwing: error)
                                    } else {
                                        continuation.finish()
                                    }
                                })
                }
            }
            continuation.onTermination = { [weak self] reason in
                guard case .cancelled = reason else { return }
                task.cancel()
                self?.transport.cancelActiveStream()
            }
        }
    }

    /// Cancels the turn in flight, if any. Its stream finishes with an error.
    public func cancel() {
        transport.cancelActiveStream()
    }

    /// Sends end-user feedback for one agent response.
    ///
    /// `conversationId` and `interactionId` come from the response's `ConversationPayload`.
    /// Also dispatches the `feedbackSubmitted` tracking event.
    public func sendFeedback(conversationId: String?,
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
        let resolvedSessionID = sessionID ?? transport.resolveSessionID()
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

    // MARK: - Private

    private func beginStreaming() -> ConciergeError? {
        if isEnded { return .conversationEnded }
        lock.lock()
        defer { lock.unlock() }
        guard !streaming else { return .turnInProgress }
        streaming = true
        return nil
    }

    private func endStreaming() {
        lock.lock()
        streaming = false
        lock.unlock()
    }
}
