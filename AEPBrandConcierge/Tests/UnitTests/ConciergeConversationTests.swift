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
import XCTest
@testable import AEPBrandConcierge

@MainActor
final class ConciergeConversationTests: XCTestCase {
    typealias Name = ConciergeConstants.TrackingEvent.Name

    private var transport: MockChatService!
    private var conversation: ConciergeConversation!
    private var dispatched: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        dispatched = []
        conversation = makeConversation()
    }

    override func tearDown() async throws {
        ConciergeAuthTokenResolver.shared.setProvider(nil)
        ConciergeActiveConversation.resetForTesting()
        SessionManager.shared.clearSession()
        try await super.tearDown()
    }

    // MARK: - send

    func test_send_attachesToken_streamsIntoMessages_andReportsTurnEvents() async throws {
        ConciergeAuthTokenResolver.shared.setProvider({ "token-123" })
        transport.plannedChunks = [payload(state: "in-progress", message: "Hel"),
                                   payload(state: "completed", message: "Hello", elements: [product("Shoe")],
                                           suggestions: ["More"], eligible: true)]

        XCTAssertEqual(conversation.send("  hi  "), .accepted)
        XCTAssertEqual(conversation.state, .responding)
        try await waitUntil { self.conversation.state == .idle }

        XCTAssertEqual(transport.lastQuery, "hi")
        XCTAssertEqual(transport.lastToken, "token-123")
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .agent])
        let agent = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(agent.text, "Hello")
        XCTAssertFalse(agent.isStreaming)
        XCTAssertTrue(agent.feedbackEnabled)
        XCTAssertEqual(agent.promptSuggestions, ["More"])
        guard case .productCard(let card) = agent.elements.first else { return XCTFail("Expected a product card") }
        XCTAssertEqual(card.productName, "Shoe")
        XCTAssertEqual(dispatched, [Name.QUERY_SUBMITTED, Name.RESPONSE_STARTED, Name.RESPONSE_COMPLETED,
                                    Name.CARDS_RENDERED])
    }

    func test_send_rejectsBlank_inProgress_andClosed_withoutReporting() async throws {
        XCTAssertEqual(conversation.send("   "), .blank)

        transport.shouldCallComplete = false
        XCTAssertEqual(conversation.send("one"), .accepted)
        try await waitUntil { self.transport.streamChatCallCount == 1 }
        let reported = dispatched
        XCTAssertEqual(conversation.send("two"), .inProgress)
        XCTAssertEqual(dispatched, reported, "a rejected send reports nothing")

        conversation.close()
        XCTAssertEqual(conversation.state, .closed(.closedByApp))
        XCTAssertEqual(conversation.send("three"), .closed)
        XCTAssertEqual(transport.streamChatCallCount, 1)
    }

    func test_failure_removesAgentMessage_setsFailed_andAllowsNextTurn() async throws {
        transport.plannedChunks = [payload(state: "in-progress", message: "Hel")]
        transport.plannedError = .timeout(30)

        conversation.send("hi")
        try await waitUntil { self.conversation.state == .failed(.timeout(30)) }
        XCTAssertEqual(conversation.messages.map(\.role), [.user])
        XCTAssertEqual(dispatched.last, Name.ERROR_OCCURRED)

        transport.plannedError = nil
        transport.plannedChunks = [payload(state: "completed", message: "ok")]
        XCTAssertEqual(conversation.send("again"), .accepted)
        try await waitUntil { self.conversation.state == .idle }
        XCTAssertEqual(conversation.messages.last?.text, "ok")
    }

    func test_httpStatus_setsFailedWithCode_reportsError_andCanBeRetried() async throws {
        transport.plannedError = .httpStatus(500)

        conversation.send("hi")
        try await waitUntil { self.conversation.state == .failed(.httpStatus(500)) }
        XCTAssertEqual(conversation.messages.map(\.role), [.user])
        XCTAssertEqual(dispatched.last, Name.ERROR_OCCURRED)
        XCTAssertEqual(transport.streamChatCallCount, 1, "an HTTP error is not resent in the background")

        transport.plannedError = nil
        transport.plannedChunks = [payload(state: "completed", message: "ok")]
        XCTAssertEqual(conversation.retry(), .accepted)
        try await waitUntil { self.conversation.state == .idle }
        XCTAssertEqual(transport.streamChatCallCount, 2)
    }

    func test_deliverHandoff_httpStatus_reportsCodeToCaller_andErrorOccurred() async throws {
        transport.plannedError = .httpStatus(401)
        var outcome: ConciergeError?

        conversation.deliverHandoff(routingHint: "x", xdmFields: ["a": 1]) { outcome = $0 }
        try await waitUntil { outcome != nil }

        XCTAssertEqual(outcome, .httpStatus(401))
        XCTAssertEqual(conversation.state, .failed(.httpStatus(401)))
        XCTAssertEqual(dispatched.last, Name.ERROR_OCCURRED)
    }

    func test_emptyResponse_addsNoAgentMessage_andReportsError() async throws {
        transport.plannedChunks = [payload(state: "completed", message: "")]

        conversation.send("hi")
        try await waitUntil { !self.conversation.isResponding }
        XCTAssertEqual(conversation.messages.map(\.role), [.user])
        XCTAssertEqual(dispatched.last, Name.ERROR_OCCURRED)
    }

    func test_cancel_keepsPartialText_reportsNoError_andFreesTransport() async throws {
        transport.shouldCallComplete = false
        conversation.send("one")
        try await waitUntil { self.transport.streamChatCallCount == 1 }
        transport.emitChunk(payload(state: "in-progress", message: "Partial"))
        try await waitUntil { self.conversation.messages.last?.text == "Partial" }
        XCTAssertEqual(conversation.messages.last?.isStreaming, true)

        conversation.cancel()

        XCTAssertEqual(conversation.state, .idle)
        XCTAssertEqual(conversation.messages.last?.text, "Partial")
        XCTAssertEqual(conversation.messages.last?.isStreaming, false)
        XCTAssertFalse(dispatched.contains(Name.ERROR_OCCURRED), "a user cancel is not an error")

        transport.shouldCallComplete = true
        transport.plannedChunks = [payload(state: "completed", message: "Hello")]
        XCTAssertEqual(conversation.send("two"), .accepted)
        try await waitUntil { self.conversation.state == .idle && self.transport.streamChatCallCount == 2 }
    }

    // MARK: - Feedback and tracking

    func test_sendFeedback_byMessageId_sendsTurnIds_andMarksMessage() async throws {
        transport.plannedChunks = [payload(state: "completed", message: "Hello", eligible: true)]
        conversation.send("hi")
        try await waitUntil { self.conversation.state == .idle }
        let agent = try XCTUnwrap(conversation.messages.last)

        conversation.sendFeedback(messageId: "missing", ConciergeFeedback(sentiment: .positive))
        conversation.sendFeedback(messageId: agent.id,
                                  ConciergeFeedback(sentiment: .negative, categories: ["Not relevant"], notes: "n"))
        try await waitUntil { self.transport.sendFeedbackCallCount == 1 }

        let ids = (transport.lastFeedbackData?["xdm"] as? [String: Any])?["conversation"] as? [String: Any]
        XCTAssertEqual(ids?["conversationID"] as? String, "conv-1")
        XCTAssertEqual(ids?["turnID"] as? String, "turn-1")
        XCTAssertEqual(conversation.messages.last?.feedback, .negative)
        XCTAssertEqual(dispatched.last, Name.FEEDBACK_SUBMITTED)
    }

    func test_track_mapsInteractionsToSDKEvents() {
        conversation.track(.ctaClicked(label: "Buy Now", url: "https://dsg.com/p/1"))
        XCTAssertEqual(dispatched, [Name.CTA_BUTTON_CLICKED, Name.LINK_CLICKED])

        dispatched = []
        conversation.track(.opened)
        conversation.track(.promptSuggestionClicked("More"))
        conversation.track(.closed)
        XCTAssertEqual(dispatched, [Name.CHAT_OPENED, Name.PROMPT_SUGGESTION_CLICKED, Name.CHAT_CLOSED])

        let linkEvents = Recorder()
        let probe = makeConversation(dispatch: linkEvents.record)
        probe.track(.linkHintClicked(LinkHint(kind: "phone", href: "tel:555")))
        XCTAssertEqual(linkEvents.events.first?.data?["origin"] as? String,
                       ConciergeConstants.TrackingEvent.LinkClickOrigin.LINK_HINT)

        dispatched = []
        conversation.close()
        conversation.track(.linkClicked(url: "https://dsg.com"))
        XCTAssertEqual(dispatched, [], "a closed conversation reports nothing")
    }

    // MARK: - Data handoffs

    func test_deliverHandoff_showsLocalMessage_sendsHint_andSkipsQuerySubmitted() async throws {
        transport.plannedChunks = [payload(state: "completed", message: "Enjoy your headphones")]
        var outcome: ConciergeError?? = .none

        let started = conversation.deliverHandoff(routingHint: "successful-checkout",
                                                  xdmFields: ["productListItems": [["name": "Headphones"]]],
                                                  localMessage: "Order confirmed") { outcome = .some($0) }
        XCTAssertTrue(started)
        try await waitUntil { outcome != nil }

        XCTAssertNil(outcome!)
        XCTAssertEqual(transport.lastQuery, "successful-checkout")
        XCTAssertNotNil(transport.lastExtraXDMFields?["productListItems"])
        XCTAssertEqual(conversation.messages.map(\.text), ["Order confirmed", "Enjoy your headphones"])
        XCTAssertEqual(conversation.messages.map(\.role), [.app, .agent])
        XCTAssertEqual(dispatched, [Name.RESPONSE_STARTED, Name.RESPONSE_COMPLETED])
    }

    func test_deliverHandoff_whileResponding_isRejected() async throws {
        transport.shouldCallComplete = false
        conversation.send("one")
        try await waitUntil { self.transport.streamChatCallCount == 1 }

        XCTAssertFalse(conversation.deliverHandoff(routingHint: "x", xdmFields: ["a": 1]))
        XCTAssertEqual(transport.streamChatCallCount, 1)
    }

    func test_deliverHandoff_silentService_timesOut_setsFailed_andFreesTransport() async throws {
        conversation = makeConversation(limits: HandoffLimits(noResponse: 0.1, ceiling: 5))
        transport.shouldCallComplete = false
        var outcome: ConciergeError?

        conversation.deliverHandoff(routingHint: "successful-checkout", xdmFields: ["a": 1]) { outcome = $0 }
        try await waitUntil { outcome != nil }

        guard case .timeout = outcome else { return XCTFail("Expected timeout, got \(String(describing: outcome))") }
        guard case .failed(.timeout) = conversation.state else { return XCTFail("Expected failed(timeout)") }
        XCTAssertEqual(conversation.retry(), .nothingToRetry, "a handoff is not retried")
        XCTAssertFalse(dispatched.contains(Name.ERROR_OCCURRED), "a handoff deadline is not reported as an error")

        transport.shouldCallComplete = true
        transport.plannedChunks = [payload(state: "completed", message: "next")]
        XCTAssertEqual(conversation.send("next"), .accepted)
        try await waitUntil { self.transport.lastQuery == "next" }
    }

    func test_deliverHandoff_ceilingCoversTokenWait_andNeverSends() async throws {
        conversation = makeConversation(limits: HandoffLimits(noResponse: 5, ceiling: 0.1))
        ConciergeAuthTokenResolver.shared.setProvider({
            try? await Task.sleep(nanoseconds: 400_000_000)
            return "late-token"
        })
        var outcome: ConciergeError?

        conversation.deliverHandoff(routingHint: "", xdmFields: ["a": 1]) { outcome = $0 }
        try await waitUntil { outcome != nil }
        guard case .timeout = outcome else { return XCTFail("Expected timeout") }

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(transport.streamChatCallCount, 0, "a turn that timed out during the token wait must not be sent")
    }

    // MARK: - Lifecycle

    func test_identityReset_closesConversation_andClearsTranscript() async throws {
        transport.shouldCallComplete = false
        ConciergeActiveConversation.activate(conversation)
        conversation.send("one")
        try await waitUntil { self.transport.streamChatCallCount == 1 }

        conversation.endForIdentityReset()

        XCTAssertEqual(conversation.state, .closed(.identityReset))
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertNil(ConciergeActiveConversation.current)
        XCTAssertEqual(conversation.send("two"), .closed)
    }

    func test_close_cancelsTurn_releasesTransport_andDeactivates() async throws {
        transport.shouldCallComplete = false
        ConciergeActiveConversation.activate(conversation)
        conversation.send("one")
        try await waitUntil { self.transport.streamChatCallCount == 1 }

        conversation.close()

        XCTAssertEqual(conversation.state, .closed(.closedByApp))
        XCTAssertFalse(conversation.isResponding)
        XCTAssertGreaterThanOrEqual(transport.cancelActiveStreamCallCount, 1)
        XCTAssertEqual(transport.invalidateCallCount, 1)
        XCTAssertNil(ConciergeActiveConversation.current)
    }

    func test_activate_onSameSurfaces_replacesPreviousConversation() {
        let first = conversation!
        let firstTransport = transport!
        ConciergeActiveConversation.activate(first)
        let second = makeConversation()

        ConciergeActiveConversation.activate(second)

        XCTAssertEqual(first.state, .closed(.replaced))
        XCTAssertEqual(firstTransport.invalidateCallCount, 1)
        XCTAssertTrue(ConciergeActiveConversation.current === second)
        XCTAssertEqual(second.state, .idle)
    }

    func test_activate_onDifferentSurfaces_coexists_andHandoffsFollowLastUsed() async throws {
        let shop = makeConversation(surfaces: ["shop"])
        let shopTransport = transport!
        let help = makeConversation(surfaces: ["help"])
        ConciergeActiveConversation.activate(shop)
        ConciergeActiveConversation.activate(help)

        XCTAssertEqual(shop.state, .idle, "a chat on other surfaces stays usable")
        XCTAssertTrue(ConciergeActiveConversation.current === help)
        XCTAssertEqual(ConciergeActiveConversation.live.count, 2)

        shopTransport.plannedChunks = [payload(state: "completed", message: "ok")]
        XCTAssertEqual(shop.send("hi"), .accepted)
        XCTAssertTrue(ConciergeActiveConversation.current === shop)
        try await waitUntil { shop.state == .idle }

        help.close()
        XCTAssertTrue(ConciergeActiveConversation.current === shop)
        XCTAssertEqual(ConciergeActiveConversation.live.count, 1)
    }

    // MARK: - Session

    func test_session_isPinned_andExpiryClosesInsteadOfMovingSession() {
        SessionManager.shared.clearSession()
        conversation = makeConversation()
        let pinned = conversation.sessionId
        XCTAssertEqual(SessionManager.shared.currentSessionIdIfActive, pinned)

        SessionManager.shared.clearSession()
        _ = SessionManager.shared.getOrCreateSessionId()

        XCTAssertEqual(conversation.sessionId, pinned, "a conversation never moves to another session")
        XCTAssertEqual(conversation.send("hi"), .closed)
        XCTAssertEqual(conversation.state, .closed(.sessionExpired))
        XCTAssertEqual(transport.streamChatCallCount, 0)
    }

    // MARK: - Retry

    func test_retry_resendsFailedTypedMessage_withoutAddingItAgain() async throws {
        transport.plannedError = .unreachable
        XCTAssertEqual(conversation.retry(), .nothingToRetry)
        conversation.send("hi")
        try await waitUntil { self.conversation.state == .failed(.unreachable) }

        transport.plannedError = nil
        transport.plannedChunks = [payload(state: "completed", message: "ok")]
        XCTAssertEqual(conversation.retry(), .accepted)
        try await waitUntil { self.conversation.state == .idle }

        XCTAssertEqual(transport.streamChatCallCount, 2)
        XCTAssertEqual(transport.lastQuery, "hi")
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(dispatched.filter { $0 == Name.QUERY_SUBMITTED }.count, 2)
        XCTAssertEqual(conversation.retry(), .nothingToRetry)
    }

    // MARK: - Elements

    func test_elements_classifyLikeTheChatUI() {
        let ctaWithoutURL = MultimodalElement(id: "c", type: "ctaButton",
                                              entityInfo: EntityInfo(primary: ActionButton(text: "Ask", url: nil)))
        let productWithoutInfo = MultimodalElement(id: "p", type: "product")
        let blankCustom = MultimodalElement(id: "x", type: "custom", rendererId: "  ")

        guard case .ctaButton("Ask", nil, _) = ConciergeElement(ctaWithoutURL) else { return XCTFail("Expected a CTA") }
        guard case .productCard = ConciergeElement(productWithoutInfo) else { return XCTFail("Expected a product card") }
        guard case .unknown = ConciergeElement(blankCustom) else { return XCTFail("Expected unknown") }
    }

    func test_ctaClicked_withoutURL_reportsOnlyCtaEvent() {
        conversation.track(.ctaClicked(label: "Ask", url: nil))
        XCTAssertEqual(dispatched, [Name.CTA_BUTTON_CLICKED])
    }

    // MARK: - ConciergeTurn

    func test_turn_appendsDeltas_completedReplaces_andReportsVisibleOnce() {
        var turn = ConciergeTurn()

        XCTAssertFalse(turn.apply(payload(state: "in-progress", message: "")))
        XCTAssertTrue(turn.apply(payload(state: "in-progress", message: "Hel")))
        XCTAssertFalse(turn.apply(payload(state: "in-progress", message: "lo")))
        XCTAssertEqual(turn.text, "Hello")
        XCTAssertFalse(turn.isComplete)

        turn.apply(payload(state: "completed", message: "Hello there", suggestions: ["More"], eligible: true))
        XCTAssertEqual(turn.text, "Hello there")
        XCTAssertTrue(turn.isComplete)
        XCTAssertTrue(turn.feedbackEligible)
        XCTAssertEqual(turn.promptSuggestions, ["More"])
    }

    func test_element_classifiesProductAndCta() {
        guard case .productCard = ConciergeElement(product("Shoe")) else { return XCTFail("Expected product card") }
        guard case .ctaButton(let label, let url, _) = ConciergeElement(cta("Buy Now")) else {
            return XCTFail("Expected CTA")
        }
        XCTAssertEqual(label, "Buy Now")
        XCTAssertEqual(url, "https://dsg.com/buy")
        guard case .productCard = ConciergeElement(MultimodalElement(id: "x", type: "mystery")) else {
            return XCTFail("Untyped elements render as product cards, as in the chat UI")
        }
    }

    // MARK: - Helpers

    private final class Recorder {
        private(set) var events: [Event] = []
        func record(_ event: Event) { events.append(event) }
    }

    private func makeConversation(limits: HandoffLimits = .standard,
                                  surfaces: [String] = [],
                                  dispatch: ((Event) -> Void)? = nil) -> ConciergeConversation {
        let configuration = ConciergeConfiguration(surfaces: surfaces)
        transport = MockChatService(configuration: configuration)
        let generation = ConciergeIdentityBoundary.shared.synchronized { ConciergeIdentityBoundary.shared.generation }
        let record = dispatch ?? { [weak self] in self?.dispatched.append($0.name) }
        let core = ConciergeConversationCore(configuration: configuration, transport: transport, identityGeneration: generation,
                                             dispatch: record)
        return ConciergeConversation(core: core, dispatch: record, handoffLimits: limits)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for condition", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func payload(state: String, message: String, elements: [MultimodalElement]? = nil,
                         suggestions: [String]? = nil, eligible: Bool = false) -> ConversationPayload {
        ConversationPayload(conversationId: "conv-1", interactionId: "turn-1", request: nil,
                            response: ConversationResponse(message: message, promptSuggestions: suggestions,
                                                           multimodalElements: elements.map { MultimodalElements(elements: $0) },
                                                           sources: nil, linkHints: nil, state: nil,
                                                           feedback: ConversationFeedbackInfo(eligible: eligible)),
                            state: state, key: nil, value: nil, maxAge: nil)
    }

    private func product(_ name: String) -> MultimodalElement {
        MultimodalElement(id: name, type: "product", entityInfo: EntityInfo(productName: name))
    }

    private func cta(_ label: String) -> MultimodalElement {
        MultimodalElement(id: label, type: "ctaButton",
                          entityInfo: EntityInfo(primary: ActionButton(text: label, url: "https://dsg.com/buy")))
    }
}
