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

/// One agent response, assembled from the stream of `ConversationPayload` chunks.
///
/// Encodes the stream's rules once so every UI reads it the same way: `IN_PROGRESS` chunks append
/// a text delta, the `COMPLETED` chunk replaces it with the full text, and the latest non-empty
/// products, suggestions, sources and link hints win.
struct ConciergeTurn {
    /// The response text so far. Markdown.
    private(set) var text = ""
    /// Every multimodal element in the response, in server order.
    private(set) var elements: [MultimodalElement] = []
    private(set) var promptSuggestions: [String] = []
    private(set) var sources: [Source] = []
    private(set) var linkHints: [LinkHint] = []
    private(set) var conversationId: String?
    private(set) var interactionId: String?
    /// Whether the `COMPLETED` chunk arrived. Products, suggestions and feedback are final only then.
    private(set) var isComplete = false
    /// Whether the response may receive thumbs up/down feedback.
    private(set) var feedbackEligible = false
    /// Whether any chunk carried text or elements. Pure heartbeats don't count.
    private(set) var hasVisibleContent = false

    init() {}

    /// Folds `payload` into the turn.
    ///
    /// - Returns: `true` for the chunk that first carries visible content, so a caller can report
    ///   `responseStarted` exactly once.
    @discardableResult
    mutating func apply(_ payload: ConversationPayload) -> Bool {
        if let id = payload.conversationId { conversationId = id }
        if let id = payload.interactionId { interactionId = id }

        guard let response = payload.response else {
            if payload.isCompleted { isComplete = true }
            return false
        }

        if payload.isInProgress {
            text += response.message
        } else if payload.isCompleted {
            text = response.message
            feedbackEligible = response.feedback?.eligible ?? false
            isComplete = true
        }
        if let chunkElements = response.multimodalElements?.elements, !chunkElements.isEmpty {
            elements = chunkElements
        }
        if let suggestions = response.promptSuggestions, !suggestions.isEmpty {
            promptSuggestions = suggestions
        }
        if let chunkSources = response.sources {
            sources = chunkSources
        }
        if let hints = response.linkHints, !hints.isEmpty {
            linkHints = hints
        }

        let chunkIsVisible = !response.message.isEmpty || !(response.multimodalElements?.elements.isEmpty ?? true)
        guard chunkIsVisible, !hasVisibleContent else { return false }
        hasVisibleContent = true
        return true
    }
}

// MARK: - Data handoff deadlines 

/// The two bounds on a data handoff turn: 10 s of service silence after the request goes out, and
/// 60 s for the whole turn.
struct HandoffLimits: Equatable {
    /// How long the service may stay silent after the request goes out. Catches a backend that
    /// never answers at all, which is the common hang and worth failing fast on.
    var noResponse: TimeInterval
    /// The hard wall-clock bound on the whole turn, from submission. Generous by design: cancelling
    /// a turn that is actively streaming throws away a reply the user was about to see.
    var ceiling: TimeInterval

    static let standard = HandoffLimits(noResponse: ConciergeConstants.Request.DATA_HANDOFF_FIRST_CHUNK_TIMEOUT,
                                        ceiling: ConciergeConstants.Request.DATA_HANDOFF_TURN_TIMEOUT)
}

/// Runs a handoff turn's two deadlines and ends the turn at most once, whichever elapses first.
///
/// - The ceiling is armed at submission, so it also covers the auth-token wait.
/// - The no-response cap is armed when the request goes out (it measures the *service's* silence)
///   and disarmed by any chunk, including a content-free heartbeat: that proves the backend is
///   alive, and the ceiling still bounds one that heartbeats forever.
/// - `disarm()` ends it; nothing fires afterwards, and arming is then a no-op.
///
/// Thread-safe. Handlers run on `queue`.
final class HandoffDeadlines {
    let limits: HandoffLimits
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var settled = false
    private var expired = false
    private var noResponse: DispatchWorkItem?
    private var ceiling: DispatchWorkItem?

    init(limits: HandoffLimits, queue: DispatchQueue) {
        self.limits = limits
        self.queue = queue
    }

    /// Whether a deadline ended the turn.
    var hasExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    /// `onExpire` receives the interval that elapsed, so the reported timeout names the real bound.
    func armCeiling(_ onExpire: @escaping (TimeInterval) -> Void) {
        arm(after: limits.ceiling, isNoResponse: false, onExpire)
    }

    func armNoResponse(_ onExpire: @escaping (TimeInterval) -> Void) {
        arm(after: limits.noResponse, isNoResponse: true, onExpire)
    }

    /// The service answered. The ceiling stays armed.
    func disarmNoResponse() {
        lock.lock()
        let item = noResponse
        noResponse = nil
        lock.unlock()
        item?.cancel()
    }

    /// The turn ended on its own.
    func disarm() {
        _ = settle(expiring: false)
    }

    private func arm(after interval: TimeInterval, isNoResponse: Bool, _ onExpire: @escaping (TimeInterval) -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.settle(expiring: true) else { return }
            onExpire(interval)
        }
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        let replaced = isNoResponse ? noResponse : ceiling
        if isNoResponse { noResponse = item } else { ceiling = item }
        lock.unlock()
        replaced?.cancel()
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Ends the deadlines once. Returns whether this call did it.
    private func settle(expiring: Bool) -> Bool {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return false
        }
        settled = true
        expired = expiring
        let items = [noResponse, ceiling]
        noResponse = nil
        ceiling = nil
        lock.unlock()
        items.forEach { $0?.cancel() }
        return true
    }
}
