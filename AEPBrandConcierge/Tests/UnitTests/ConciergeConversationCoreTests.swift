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

import XCTest
@testable import AEPBrandConcierge

final class ConciergeConversationCoreTests: XCTestCase {

    private var transport: MockChatService!
    private var core: ConciergeConversationCore!

    override func setUp() {
        super.setUp()
        let configuration = ConciergeConfiguration()
        transport = MockChatService(configuration: configuration)
        let generation = ConciergeIdentityBoundary.shared.synchronized { ConciergeIdentityBoundary.shared.generation }
        core = ConciergeConversationCore(configuration: configuration, transport: transport, identityGeneration: generation)
    }

    override func tearDown() {
        ConciergeAuthTokenResolver.shared.setProvider(nil)
        super.tearDown()
    }

    func test_send_attachesTokenAndXDM_andYieldsChunksUntilComplete() async throws {
        ConciergeAuthTokenResolver.shared.setProvider({ "token-123" })
        transport.plannedChunks = [payload(state: "in-progress", message: "Hel"),
                                   payload(state: "completed", message: "Hello")]

        var received: [String?] = []
        for try await chunk in core.send("hi", xdmFields: ["commerce": ["order": "1"]]) {
            received.append(chunk.response?.message)
        }

        XCTAssertEqual(received, ["Hel", "Hello"])
        XCTAssertEqual(transport.lastQuery, "hi")
        XCTAssertEqual(transport.lastToken, "token-123")
        XCTAssertNotNil(transport.lastExtraXDMFields?["commerce"])
    }

    func test_send_whileStreaming_failsWithTurnInProgress() async throws {
        transport.shouldCallComplete = false
        let firstStarted = expectation(description: "first turn reached transport")
        transport.onStreamChat = { firstStarted.fulfill() }
        let first = core.send("one")
        let firstConsumer = Task { for try await _ in first {} }
        await fulfillment(of: [firstStarted], timeout: 2)

        do {
            for try await _ in core.send("two") {}
            XCTFail("Expected turnInProgress")
        } catch ConciergeError.turnInProgress {
        }

        transport.triggerCompletion()
        _ = try await firstConsumer.value
    }

    func test_send_failure_finishesStreamWithError_andAllowsNextTurn() async throws {
        transport.plannedError = .timeout(30)
        do {
            for try await _ in core.send("hi") {}
            XCTFail("Expected timeout")
        } catch ConciergeError.timeout {
        }

        transport.plannedError = nil
        for try await _ in core.send("again") {}
        XCTAssertEqual(transport.streamChatCallCount, 2)
    }

    func test_identityReset_endsCore() async throws {
        core.endForIdentityReset()

        XCTAssertTrue(core.isEnded)
        do {
            for try await _ in core.send("hi") {}
            XCTFail("Expected conversationEnded")
        } catch ConciergeError.conversationEnded {
        }
        XCTAssertEqual(transport.streamChatCallCount, 0)
    }

    func test_sendFeedback_sendsTurnIdsAndToken() {
        ConciergeAuthTokenResolver.shared.setProvider({ "token-123" })
        let sent = expectation(description: "feedback sent")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [transport] _ in
            if transport?.sendFeedbackCallCount == 1 { sent.fulfill() }
        }
        defer { poll.invalidate() }

        core.sendFeedback(conversationId: "conv-1", interactionId: "turn-1", sentiment: .negative,
                          reasons: ["Not relevant"], notes: "n")
        wait(for: [sent], timeout: 2)

        let conversation = (transport.lastFeedbackData?["xdm"] as? [String: Any])?["conversation"] as? [String: Any]
        XCTAssertEqual(conversation?["conversationID"] as? String, "conv-1")
        XCTAssertEqual(conversation?["turnID"] as? String, "turn-1")
        XCTAssertEqual(transport.lastFeedbackToken, "token-123")
    }

    func test_ctaButtonClicked_tracksCtaAndLinkClick() {
        let events = ConciergeAnalyticsEvent.ctaButtonClicked(label: "Buy Now", url: "https://dsg.com/p/1").trackingEvents
            .map { $0.toEvent() }

        XCTAssertEqual(events.map(\.name), [ConciergeConstants.TrackingEvent.Name.CTA_BUTTON_CLICKED,
                                            ConciergeConstants.TrackingEvent.Name.LINK_CLICKED])
    }

    private func payload(state: String, message: String) -> ConversationPayload {
        ConversationPayload(conversationId: "conv-1", interactionId: "turn-1", request: nil,
                            response: ConversationResponse(message: message, promptSuggestions: nil, multimodalElements: nil,
                                                           sources: nil, linkHints: nil, state: nil, feedback: nil),
                            state: state, key: nil, value: nil, maxAge: nil)
    }
}
