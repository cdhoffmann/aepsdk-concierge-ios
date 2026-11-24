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

import Foundation
import AEPServices

@MainActor
struct ResponseElementPlan {
    enum Target {
        case native(NativeCardStore.Activation)
        case product(MultimodalElement)
        case cta(ActionButton)
    }

    let targets: [Target]

    var hasRenderableElements: Bool {
        targets.contains { target in
            switch target {
            case .native, .cta: return true
            case .product(let element): return element.entityInfo != nil
            }
        }
    }

    var cardsRenderedEvent: ConciergeTrackingEvent? {
        ConciergeTrackingEvent.cardsRendered(for: productElements)
    }

    private var productElements: [MultimodalElement] {
        targets.compactMap { target in
            if case .product(let element) = target { return element }
            return nil
        }
    }

    func makeMessages(nativeCards: NativeCardStore, payload: ConversationPayload, sessionId: String?,
                      promptSuggestions: [String]) -> [Message] {
        let elements = productElements
        let products = elements.compactMap { element -> ProductCardData? in
            guard let entityInfo = element.entityInfo else { return nil }
            return ProductCardData(entityInfo: entityInfo, element: element)
        }
        let productMessage: Message?
        if elements.count == 1, let product = products.first {
            productMessage = Message(template: .productCard(product))
        } else if elements.count > 1 {
            // Legacy batching counts element candidates, even when their product projection is empty.
            productMessage = Message(template: .carouselGroup(products.map {
                Message(template: .productCarouselCard($0))
            }))
        } else {
            productMessage = nil
        }

        var messages: [Message] = []
        messages.reserveCapacity(targets.count + promptSuggestions.count)
        var productEmitted = false
        var productIndex: Int?
        var lastNativeIndex: Int?
        for target in targets {
            switch target {
            case .native(let activation):
                guard let card = nativeCards.activate(activation, payload: payload, sessionId: sessionId) else { continue }
                lastNativeIndex = messages.count
                messages.append(Message(nativeCardId: card.cardId))
            case .product:
                guard !productEmitted else { continue }
                productEmitted = true
                if let productMessage {
                    if !products.isEmpty { productIndex = messages.count }
                    messages.append(productMessage)
                }
            case .cta(let action):
                messages.append(Message(template: .ctaButton(action)))
            }
        }
        if !promptSuggestions.isEmpty {
            if let lastNativeIndex {
                messages[productIndex ?? lastNativeIndex].promptSuggestions = promptSuggestions
            } else {
                messages.append(contentsOf: promptSuggestions.map {
                    Message(template: .promptSuggestion(text: $0))
                })
            }
        }
        return messages
    }
}

/// How a multimodal element is shown. The one classification rule for the SDK's chat UI and for
/// `ConciergeElement`, so both agree on what a response contains.
enum MultimodalElementKind {
    /// A `custom` element with a non-blank `rendererId`.
    case custom(rendererId: String)
    /// A `ctaButton` element with `entity_info.primary`.
    case ctaButton(ActionButton)
    /// Any other element.
    case productCard
    /// A `custom` element without a `rendererId`, or a `ctaButton` without `entity_info.primary`.
    case invalid
}

extension MultimodalElement {
    var kind: MultimodalElementKind {
        if type == "custom" {
            guard let id = rendererId, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalid }
            return .custom(rendererId: id)
        }
        if elementType == .ctaButton {
            guard let action = entityInfo?.primary else { return .invalid }
            return .ctaButton(action)
        }
        return .productCard
    }
}

@MainActor
enum ResponseElementResolver {
    private static let LOG_TAG = "ResponseElementResolver"

    static func resolve(_ elements: [MultimodalElement], turnId: UUID, nativeCards: NativeCardStore,
                        allowsNativeCards: Bool = true) -> ResponseElementPlan {
        var targets: [ResponseElementPlan.Target] = []
        targets.reserveCapacity(elements.count)
        var occurrencePositions: [NativeCardStore.Occurrence: Int] = [:]
        for (position, element) in elements.enumerated() {
            switch element.kind {
            case .invalid:
                Log.warning(label: LOG_TAG, element.type == "custom"
                    ? "Rejected custom element at position \(position): missing or invalid rendererId."
                    : "Skipping ctaButton element '\(element.id ?? "unknown")': missing entity_info.primary.")
            case .ctaButton(let action):
                targets.append(.cta(action))
            case .productCard:
                targets.append(.product(element))
            case .custom(let id):
                guard let registration = NativeCardRegistry.registration(for: id) else {
                    Log.warning(label: LOG_TAG, "Skipping custom element at position \(position): no renderer registered for rendererId '\(id)'.")
                    continue
                }
                // Only completed custom elements may activate.
                guard allowsNativeCards else { continue }
                let occurrence = NativeCardStore.Occurrence(element: element, rendererId: id,
                                                            position: position, turnId: turnId)
                let existingPosition = nativeCards.position(for: occurrence)
                if let originalPosition = occurrencePositions[occurrence] ?? existingPosition,
                   originalPosition != position {
                    Log.warning(label: LOG_TAG,
                                "Rejected native card element at position \(position): duplicate element id for rendererId '\(id)'.")
                } else if !element.hasCompleteRawElement {
                    Log.warning(label: LOG_TAG, "Rejected native card element with invalid, over-budget, or inexact raw JSON.")
                } else {
                    occurrencePositions[occurrence] = position
                    // Decoding already enforced the JSON budget; build the renderer's copy only for new cards.
                    if existingPosition == nil {
                        targets.append(.native(NativeCardStore.Activation(occurrence: occurrence, position: position,
                                                                         rendererId: id,
                                                                         element: element.rawElement,
                                                                         registration: registration)))
                    }
                }
            }
        }
        return ResponseElementPlan(targets: targets)
    }
}
