# Headless Core (Thin) — Spec

Status: POC on `headless_thin` (iOS). Ticket: PLAT-320683.
Companion: [headless-core-plus-spec.md](headless-core-plus-spec.md) (thin + turn assembler + automatic turn events).

## 1. Goal

Let a customer (DSG) build its own chat UI while the SDK keeps owning everything that must be
identical to the SDK UI: configuration, session, auth-token pass-through, XDM context, the SSE
transport, feedback, and the analytics event contract.

Constraints:

- **Minimal change to the existing SDK.** Pull the networking layer out behind one public type and
  make the existing UI use it. No rewrite of `ChatController`'s turn engine, and no new view models.
- **No breaking changes.** `show`, `wrap`, `present`, `sendDataHandoff`, theming and the other
  existing APIs behave as before.
- **One code path.** The SDK UI and headless apps send turns through the same `ConciergeConversationCore`.

Non-goals: SDK-provided message models, welcome content, speech, theming, or server changes.

## 2. Public API

```swift
// Entry point. Resolves config the same way `show(surfaces:)` does.
let core = try await Concierge.conversationCore(surfaces: ["web://…"])   // throws ConciergeError.configurationUnavailable

public final class ConciergeConversationCore {
    public let configuration: ConciergeConfiguration
    public var sessionId: String { get }
    public var isEnded: Bool { get }                // true after an identity reset

    /// Raw service chunks. Token + XDM context attached automatically; `xdmFields` merged for this turn.
    public func send(_ query: String, xdmFields: [String: Any]? = nil)
        -> AsyncThrowingStream<ConversationPayload, Error>
    public func cancel()
    public func sendFeedback(conversationId: String?, interactionId: String?,
                             sentiment: FeedbackSentiment, reasons: [String] = [], notes: String = "")
}

// Analytics from a custom UI. Same Edge events as the SDK UI; gated by setEdgeTrackingEnabled.
Concierge.track(_ event: ConciergeAnalyticsEvent)

public enum ConciergeAnalyticsEvent {
    case chatOpened, chatClosed(durationMillis: Int64)
    case querySubmitted(query: String, xdmFields: [String: Any])
    case responseStarted(conversationId: String?, interactionId: String?)
    case responseCompleted(conversationId: String?, interactionId: String?)
    case productsRendered([MultimodalElement])
    case productClicked(MultimodalElement)               // + linkClicked(origin: productCard)
    case ctaButtonClicked(label: String, url: String)    // + linkClicked(origin: cta)  ← "Buy Now"
    case linkClicked(url: String)
    case promptSuggestionClicked(String)
    case errorOccurred(String)
}
```

Other public surface changes:

| Change | Why |
| --- | --- |
| `ConciergeError` made `public`, adds `turnInProgress`, `conversationEnded`, `configurationUnavailable` | `send` throws it |
| `ConversationPayload.isInProgress` / `.isCompleted` | stream state strings are internal constants |
| `MultimodalElementType` and `MultimodalElement.elementType` made `public` | to tell CTA buttons from product cards |

Existing public wire models (`ConversationPayload`, `ConversationResponse`, `MultimodalElement`,
`EntityInfo`, `ActionButton`, `Source`, `LinkHint`, `FeedbackSentiment`) are reused unchanged.

## 3. Behavior contract

| # | Rule |
| --- | --- |
| B1 | Each `send` resolves the token from `setAuthTokenProvider` and attaches the secure-context data part, exactly as the SDK UI does. |
| B2 | The XDM context (`updateXDMContext`) is snapshotted **before** the token wait; `xdmFields` are merged over it for this turn only. |
| B3 | One turn per core at a time. A second `send` while streaming throws `turnInProgress` without disturbing the first. |
| B4 | The stream yields chunks in arrival order and finishes when the service closes, or throws a `ConciergeError` (`timeout`, `unreachable`, …). |
| B5 | Cancelling the consuming task, or calling `cancel()`, cancels the request. |
| B6 | After `MobileCore.resetIdentities()` the core is ended: `send` throws `conversationEnded` and feedback is dropped. The app must request a new core. |
| B7 | `sendFeedback` sends the same `CONVERSATION_FEEDBACK` Edge payload as the SDK UI and resolves the token per call. |
| B8 | `Concierge.track` emits the same event names and data as the SDK UI, so reporting doesn't need to tell the two UIs apart. |

## 4. SDK changes (as built in the POC)

| File | Change |
| --- | --- |
| `Core/ConciergeConversationCore.swift` (new) | Wraps `ConciergeChatService`: token resolution, XDM snapshot and merge, single-flight, identity-reset end, feedback payload builder. |
| `Core/Concierge+Headless.swift` (new) | `Concierge.conversationCore(surfaces:)`, `Concierge.track`, `ConciergeAnalyticsEvent`. |
| `Controllers/ChatController.swift` | Holds a `core` instead of a `ConciergeChatService`. Sends through `core.requestContext` / `core.stream`; feedback goes through `core.sendFeedback`; identity reset calls `core.endForIdentityReset()`. The turn engine is otherwise untouched. |
| `Core/Concierge+PublicAPI.swift` | `fetchChatConfiguration` gains an `onFailure` callback, so the async entry can throw instead of hanging. |
| `Models/Network/ConciergeError.swift`, `ConversationPayload.swift`, `ConversationResponse.swift` | Public exposure, listed above. |

What stays SDK-UI only: transcript (`Message`), welcome content, data-handoff caps and timeouts,
background recovery, speech, theming, link handling and the overlay.

Validation: all 953 existing and new unit tests pass. `ConciergeConversationCoreTests` covers the
token and XDM attachment, single-flight, failure then retry, identity reset, feedback payload, and
CTA tracking.

## 5. Customer responsibilities (what DSG writes)

See `ConciergeDemoApp/HeadlessCoreChatView.swift` on `headless_thin`. It is about 230 lines of app
code for the model and UI.

```swift
var text = ""
var started = false
Concierge.track(.querySubmitted(query: q, xdmFields: [:]))
for try await chunk in core.send(q) {
    guard let r = chunk.response else { continue }
    let elements = r.multimodalElements?.elements ?? []
    if !started, !r.message.isEmpty || !elements.isEmpty {
        started = true
        Concierge.track(.responseStarted(conversationId: chunk.conversationId, interactionId: chunk.interactionId))
    }
    if chunk.isInProgress { text += r.message }            // delta
    else if chunk.isCompleted {                            // full replace + final content
        text = r.message
        products = elements.filter { $0.elementType != .ctaButton }
        ctas = elements.filter { $0.elementType == .ctaButton }.compactMap { $0.entityInfo?.primary }
        Concierge.track(.responseCompleted(conversationId: chunk.conversationId, interactionId: chunk.interactionId))
        if !products.isEmpty { Concierge.track(.productsRendered(products)) }
    }
}
// Buy Now tap:
Concierge.track(.ctaButtonClicked(label: cta.text, url: cta.url!))
```

DSG owns:

- the transcript, rendering, markdown and citations;
- the accumulation rules (delta vs replace, which chunk is final);
- empty-response handling, error copy, and retry and timeout policy;
- all analytics call sites, including the `responseStarted` "first visible content" rule;
- welcome content and feedback reasons, and re-creating the core after an identity reset.

## 6. Gaps to close for production

| # | Gap | Proposal |
| --- | --- | --- |
| G1 | A headless core's **in-flight** stream is not cancelled on identity reset. Only cores owned by SDK sessions get `endForIdentityReset()`; a headless core only rejects new calls (generation check). | Register live cores in a weak set in `Concierge` and end them in the existing reset fan-out (`Concierge.swift` ~212/328). |
| G2 | SSE parsing splits per `didReceive`, so a `data:` line spanning two packets is dropped. This is pre-existing and affects both UIs. | Buffer partial lines in the transport. |
| G3 | HTTP status is ignored: a 4xx/5xx with a body completes "successfully" and becomes an empty response. | Check `HTTPURLResponse.statusCode`; map to `unauthorized` / `rateLimited` / `server(code:)`. Requires new error cases. |
| G4 | Turn caps (no-response, wall-clock) and background recovery live in `ChatController`, so headless turns have only the 30 s read timeout. | Keep as customer policy in thin. Plus could optionally move caps into the core. |
| G5 | Accumulation and analytics rules are duplicated in every customer UI and drift silently (ex: `responseStarted` gating). | This is the case for the plus variant. |
| G6 | Adding cases to a public `ConciergeError` is source-breaking for exhaustive `switch`. | Document `@unknown default`, or expose a struct with a `kind`. Decide before GA. |
| G7 | Welcome prompts, disclaimer and feedback options come from theme JSON, which is UI-only. | Out of scope; DSG hard-codes or uses its own CMS. |
| G8 | No module split. Everything ships in `AEPBrandConcierge` (SwiftUI is linked). | Phase 2: `AEPBrandConciergeCore` subspec/SPM target. Blockers: `Message`, `MessageTemplate`, `ProductCardData`, `WelcomePromptSuggestion`, `ConciergeLinkHandler`, `ConciergeAppState` import UI frameworks and must stay out of Core. |
| G9 | Data handoff for headless is `core.send(routingHint, xdmFields:)` with no handoff caps or completion semantics. | Document the pattern; add `sendDataHandoff` on the core if DSG needs the timeouts. |

## 7. Server

There are **no server changes required**. The core sends the same requests as the SDK UI.

Nice-to-haves that shrink customer code:

- an explicit end-of-turn event;
- status codes on errors;
- welcome and feedback config via API.

## 8. Android parity

Mirror the same shape:

- `Concierge.conversationCore(surfaces)` (suspend);
- `ConciergeConversationCore.send(): Flow<ConversationPayload>`, `cancel()` and `sendFeedback()`;
- `Concierge.track(ConciergeAnalyticsEvent)`;
- public `ConciergeError`.

Event names and payloads must match iOS (B8).

## 9. Estimates (per platform)

| | Adobe | DSG |
| --- | --- | --- |
| Thin (this spec) | 2–3 wks (POC → prod: G1–G3, G6, docs, Android port per platform) | 9–13 wks |

## 10. Migration

The change is additive. Existing integrations are untouched. A customer can ship headless on one
surface and the SDK UI on another, since both use the same core, token provider and XDM context.
