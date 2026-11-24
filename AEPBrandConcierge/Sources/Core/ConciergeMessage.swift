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

/// One message in a `ConciergeConversation` transcript.
public struct ConciergeMessage: Identifiable {
    /// Who wrote a `ConciergeMessage`.
    public enum Role: Equatable {
        case user
        case agent
        /// Text the app added to the transcript, such as a data handoff's `localMessage`.
        case app
    }

    public let id: String
    public let role: Role
    /// Markdown for an agent message; plain text for a user message.
    public internal(set) var text: String
    /// Whether the agent is still streaming this message. Elements, sources and suggestions are
    /// final only once this is `false`.
    public internal(set) var isStreaming: Bool
    public internal(set) var elements: [ConciergeElement]
    public internal(set) var sources: [Source]
    /// Known links in `text` and how to present them (ex: a phone number or a store page).
    public internal(set) var linkHints: [LinkHint]
    public internal(set) var promptSuggestions: [String]
    /// Whether this message accepts `ConciergeConversation.sendFeedback(messageId:_:)`.
    public internal(set) var feedbackEnabled: Bool
    /// The feedback already sent for this message, if any.
    public internal(set) var feedback: FeedbackSentiment?

    init(id: String, role: Role, text: String, isStreaming: Bool = false, elements: [ConciergeElement] = [],
         sources: [Source] = [], linkHints: [LinkHint] = [], promptSuggestions: [String] = [],
         feedbackEnabled: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.elements = elements
        self.sources = sources
        self.linkHints = linkHints
        self.promptSuggestions = promptSuggestions
        self.feedbackEnabled = feedbackEnabled
    }
}

/// A multimodal element in an agent message, classified the way the SDK's chat UI classifies it.
public enum ConciergeElement {
    /// A product or content card.
    case productCard(ConciergeProductCard)
    /// A standalone call-to-action button (ex: "Buy Now"). `url` is `nil` for a button the app
    /// handles itself.
    case ctaButton(label: String, url: String?, raw: MultimodalElement)
    /// A `custom` element for an app-defined renderer, matched by `rendererId`.
    case custom(rendererId: String, raw: MultimodalElement)
    /// An element missing required fields. Not shown by the SDK UI.
    case unknown(type: String?, raw: MultimodalElement)

    /// The element exactly as received, for fields this type doesn't model.
    public var raw: MultimodalElement {
        switch self {
        case .productCard(let card): return card.raw
        case .ctaButton(_, _, let raw), .custom(_, let raw), .unknown(_, let raw): return raw
        }
    }

    /// Classified by `MultimodalElement.kind`, the same rule the SDK's chat UI uses.
    init(_ element: MultimodalElement) {
        switch element.kind {
        case .custom(let rendererId): self = .custom(rendererId: rendererId, raw: element)
        case .ctaButton(let action): self = .ctaButton(label: action.text, url: action.url, raw: element)
        case .productCard: self = .productCard(ConciergeProductCard(element))
        case .invalid: self = .unknown(type: element.type, raw: element)
        }
    }

    var isRenderable: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// A product or content card. Fields come from the element's `entity_info`.
public struct ConciergeProductCard {
    public let id: String?
    public let productName: String?
    public let productDescription: String?
    public let description: String?
    public let productPageURL: String?
    public let productImageURL: String?
    public let productPrice: String?
    public let productWasPrice: String?
    public let productBadge: String?
    /// The card's main button (ex: "Buy Now").
    public let primary: ActionButton?
    public let secondary: ActionButton?
    public let raw: MultimodalElement

    init(_ element: MultimodalElement) {
        let info = element.entityInfo
        id = element.id
        productName = info?.productName
        productDescription = info?.productDescription
        description = info?.description
        productPageURL = info?.productPageURL
        productImageURL = info?.productImageURL
        productPrice = info?.productPrice
        productWasPrice = info?.productWasPrice
        productBadge = info?.productBadge
        primary = info?.primary
        secondary = info?.secondary
        raw = element
    }
}

/// End-user feedback on one agent message.
public struct ConciergeFeedback {
    public var sentiment: FeedbackSentiment
    /// The selected feedback categories, as shown to the user.
    public var categories: [String]
    public var notes: String

    public init(sentiment: FeedbackSentiment, categories: [String] = [], notes: String = "") {
        self.sentiment = sentiment
        self.categories = categories
        self.notes = notes
    }
}

/// What a `ConciergeConversation` is doing.
public enum ConciergeConversationState: Equatable {
    /// Ready to send a message.
    case idle
    /// Waiting for or receiving an agent response.
    case responding
    /// The last response failed with `error`. The conversation can still send messages, or
    /// `retry()` the failed one.
    case failed(ConciergeError)
    /// The conversation ended for `reason` and sends nothing more. Create a new one.
    case closed(ConciergeCloseReason)

    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}

/// Why a `ConciergeConversation` closed.
public enum ConciergeCloseReason: Equatable {
    /// The app called `close()`.
    case closedByApp
    /// Another conversation was opened on the same surfaces, headless or by the SDK's chat UI. One
    /// conversation is live per surface set.
    case replaced
    /// The backend session expired (30 minutes without a request).
    case sessionExpired
    /// `MobileCore.resetIdentities()` was called.
    case identityReset
}

/// Whether `ConciergeConversation.send(_:)` started a turn.
public enum ConciergeSendResult: Equatable {
    case accepted
    /// The text was empty after trimming whitespace.
    case blank
    /// A response is already in progress. Wait for `state` to leave `.responding`, or `cancel()`.
    case inProgress
    /// The conversation is closed.
    case closed
    /// An identity reset is pending.
    case resetPending
    /// `retry()` was called, but the last turn didn't fail or wasn't a typed message.
    case nothingToRetry
}

/// A user interaction a custom chat UI reports with `ConciergeConversation.track(_:)`.
///
/// Turn events (query submitted, response started and completed, cards rendered, errors) and
/// feedback are reported by the conversation itself; report only these.
public enum ConciergeInteraction {
    /// The conversation was shown.
    case opened
    /// The conversation was hidden. Reports the time since the last `opened`.
    case closed
    /// A prompt suggestion was tapped. This doesn't send it; call `send(_:)` as well.
    case promptSuggestionClicked(String)
    /// A `ConciergeElement.ctaButton` was tapped.
    case ctaClicked(label: String, url: String?)
    /// A product card was tapped, outside its buttons.
    case productCardClicked(ConciergeProductCard)
    /// A product card button (ex: "Buy Now") was tapped.
    case productActionClicked(ConciergeProductCard, ActionButton)
    /// A citation was tapped.
    case sourceClicked(Source)
    /// A link in the message text was tapped.
    case linkClicked(url: String)
    /// A link in the message text that has a `LinkHint` was tapped.
    case linkHintClicked(LinkHint)
}
