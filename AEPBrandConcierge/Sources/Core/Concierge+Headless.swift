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

/// Public API for apps that render their own chat UI on top of `ConciergeConversationCore`.
public extension Concierge {

    /// Creates a conversation core for `surfaces`, for apps that render their own chat UI.
    ///
    /// Resolves configuration the same way `show(surfaces:)` does, so the Concierge extension,
    /// Edge and Edge Identity must be registered. Each call returns a new core; keep one per
    /// on-screen conversation.
    ///
    /// - Throws: `ConciergeError.configurationUnavailable` if configuration can't be resolved (ex:
    ///   Edge Identity not yet ready, or an identity reset happened while resolving).
    static func conversationCore(surfaces: [String]) async throws -> ConciergeConversationCore {
        try await withCheckedThrowingContinuation { continuation in
            fetchChatConfiguration(forSurfaces: surfaces,
                                   onFailure: { continuation.resume(throwing: ConciergeError.configurationUnavailable) },
                                   completion: { config, generation in
                                       continuation.resume(returning: ConciergeConversationCore(
                                           configuration: config,
                                           urlSessionConfiguration: resolvedURLSessionConfiguration(),
                                           identityGeneration: generation))
                                   })
        }
    }

    /// Dispatches a Brand Concierge analytics event from a custom chat UI.
    ///
    /// Events reach Edge only after `setEdgeTrackingEnabled(enable: true)`, exactly as they do for
    /// the SDK's chat UI, so reporting built on Concierge events works the same for both.
    static func track(_ event: ConciergeAnalyticsEvent) {
        for trackingEvent in event.trackingEvents {
            MobileCore.dispatch(event: trackingEvent.toEvent())
        }
    }
}

/// An analytics event a custom chat UI reports through `Concierge.track(_:)`.
///
/// Mirrors the events the SDK's chat UI dispatches. Feedback is not listed: it is tracked by
/// `ConciergeConversationCore.sendFeedback`.
public enum ConciergeAnalyticsEvent {
    case chatOpened
    case chatClosed(durationMillis: Int64)
    /// Report before calling `send`. Pass the same `xdmFields` given to `send`, if any.
    case querySubmitted(query: String, xdmFields: [String: Any])
    /// Report on the first chunk that carries text or product elements.
    case responseStarted(conversationId: String?, interactionId: String?)
    /// Report on the `COMPLETED` chunk.
    case responseCompleted(conversationId: String?, interactionId: String?)
    /// Report once per turn when product cards are shown.
    case productsRendered([MultimodalElement])
    /// A product card tap. Also reports `linkClicked` for the product page URL.
    case productClicked(MultimodalElement)
    /// A CTA button tap (ex: "Buy Now"). Also reports `linkClicked`.
    case ctaButtonClicked(label: String, url: String)
    case linkClicked(url: String)
    case promptSuggestionClicked(String)
    case errorOccurred(String)

    var trackingEvents: [ConciergeTrackingEvent] {
        typealias Origin = ConciergeConstants.TrackingEvent.LinkClickOrigin
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        switch self {
        case .chatOpened:
            return [.chatOpened(epochTime: now)]
        case .chatClosed(let durationMillis):
            return [.chatClosed(epochTime: now, durationMillis: durationMillis)]
        case .querySubmitted(let query, let xdmFields):
            return [.querySubmitted(query: query, xdmFields: xdmFields)]
        case .responseStarted(let conversationId, let interactionId):
            return [.responseStarted(conversationId: conversationId ?? "unknown", interactionId: interactionId ?? "unknown")]
        case .responseCompleted(let conversationId, let interactionId):
            return [.responseCompleted(conversationId: conversationId ?? "unknown", interactionId: interactionId ?? "unknown")]
        case .productsRendered(let elements):
            let dicts = elements.compactMap { element -> [String: Any]? in
                guard let info = element.entityInfo else { return nil }
                var dict: [String: Any] = [:]
                if let name = info.productName { dict["productName"] = name }
                if let url = info.productPageURL { dict["productPageURL"] = url }
                if let price = info.productPrice { dict["productPrice"] = price }
                return dict
            }
            guard !dicts.isEmpty else { return [] }
            return [.cardsRendered(displayMode: dicts.count == 1 ? "single" : "carousel", elements: dicts)]
        case .productClicked(let element):
            let info = element.entityInfo
            var dict: [String: Any] = [:]
            if let name = info?.productName { dict["productName"] = name }
            if let description = info?.productDescription { dict["productDescription"] = description }
            if let url = info?.productPageURL { dict["productPageURL"] = url }
            if let price = info?.productPrice { dict["productPrice"] = price }
            if let badge = info?.productBadge { dict["productBadge"] = badge }
            var events: [ConciergeTrackingEvent] = [.cardClicked(element: dict)]
            if let url = info?.productPageURL {
                events.append(.linkClicked(url: url, origin: Origin.PRODUCT_CARD))
            }
            return events
        case .ctaButtonClicked(let label, let url):
            return [.ctaButtonClicked(label: label, linkUrl: url), .linkClicked(url: url, origin: Origin.CTA)]
        case .linkClicked(let url):
            return [.linkClicked(url: url, origin: Origin.INLINE)]
        case .promptSuggestionClicked(let suggestion):
            return [.promptSuggestionClicked(suggestion: suggestion)]
        case .errorOccurred(let message):
            return [.errorOccurred(errorMessage: message)]
        }
    }
}
