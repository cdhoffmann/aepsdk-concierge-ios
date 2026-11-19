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
/// products, suggestions, sources and link hints win. The SDK's chat UI uses this same type.
public struct ConciergeTurn {
    /// The response text so far. Markdown.
    public private(set) var text = ""
    /// Every multimodal element in the response, in server order.
    public private(set) var elements: [MultimodalElement] = []
    public private(set) var promptSuggestions: [String] = []
    public private(set) var sources: [Source] = []
    public private(set) var linkHints: [LinkHint] = []
    public private(set) var conversationId: String?
    public private(set) var interactionId: String?
    /// Whether the `COMPLETED` chunk arrived. Products, suggestions and feedback are final only then.
    public private(set) var isComplete = false
    /// Whether the response may receive thumbs up/down feedback.
    public private(set) var feedbackEligible = false
    /// Whether any chunk carried text or elements. Pure heartbeats don't count.
    public private(set) var hasVisibleContent = false

    /// Product card elements (everything that isn't a standalone CTA button).
    public var products: [MultimodalElement] { elements.filter { $0.elementType != .ctaButton } }

    /// Standalone CTA buttons (ex: "Buy Now"), each with its label and URL.
    public var ctaButtons: [ActionButton] {
        elements.filter { $0.elementType == .ctaButton }.compactMap { $0.entityInfo?.primary }
    }

    /// A finished turn with no text and no elements: the service answered with nothing to show.
    public var isEmpty: Bool { text.isEmpty && elements.isEmpty }

    public init() {}

    /// Folds `payload` into the turn.
    ///
    /// - Returns: `true` for the chunk that first carries visible content, so a caller can report
    ///   `responseStarted` exactly once.
    @discardableResult
    public mutating func apply(_ payload: ConversationPayload) -> Bool {
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
