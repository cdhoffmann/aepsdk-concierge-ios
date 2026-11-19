# Headless Core (Plus) — Spec

Status: POC on `headless_plus` (stacked on `headless_thin`, iOS). Ticket: PLAT-320683.
Base: [headless-core-thin-spec.md](headless-core-thin-spec.md). Everything there applies; this spec lists only the additions.

## 1. Goal

Same minimal-change thin core, plus two helpers that remove the parts customers are most likely
to get wrong. These are also the parts that break reporting:

1. **`ConciergeTurn`**: a pure assembler that folds stream chunks into one response.
2. **`core.sendTurn(_:)`**: streams assembled turns and reports turn analytics automatically.

The SDK UI uses `ConciergeTurn` too, so stream semantics are defined in exactly one place.

## 2. Public API (additions)

```swift
public struct ConciergeTurn {
    public private(set) var text: String              // IN_PROGRESS appends, COMPLETED replaces
    public private(set) var elements: [MultimodalElement]
    public var products: [MultimodalElement] { get } // non-CTA elements
    public var ctaButtons: [ActionButton] { get }    // standalone CTAs ("Buy Now")
    public private(set) var promptSuggestions: [String]
    public private(set) var sources: [Source]
    public private(set) var linkHints: [LinkHint]
    public private(set) var conversationId: String?
    public private(set) var interactionId: String?
    public private(set) var isComplete: Bool
    public private(set) var feedbackEligible: Bool
    public private(set) var hasVisibleContent: Bool
    public var isEmpty: Bool { get }

    public init()
    @discardableResult
    public mutating func apply(_ payload: ConversationPayload) -> Bool   // true on first visible content
}

extension ConciergeConversationCore {
    /// Yields the updated turn per chunk; reports querySubmitted, responseStarted,
    /// responseCompleted, cardsRendered and errorOccurred. Empty response → throws invalidResponseData.
    public func sendTurn(_ query: String, xdmFields: [String: Any]? = nil)
        -> AsyncThrowingStream<ConciergeTurn, Error>
}
```

`send(_:)` (raw chunks) stays available for customers who want full control.

## 3. Behavior contract (additions)

| # | Rule |
| --- | --- |
| P1 | `apply` encodes the stream rules once: delta append on `IN_PROGRESS`; full replace plus `feedbackEligible` and `isComplete` on `COMPLETED`; the latest non-empty elements, suggestions and link hints win; sources take the latest value. |
| P2 | `apply` returns `true` exactly once per turn, on the first chunk with text **or** elements. Heartbeats don't count. This is the `responseStarted` rule, shared with Android. |
| P3 | `sendTurn` reports `querySubmitted` with the **same** XDM snapshot the request carries. |
| P4 | `responseCompleted` is reported only for a non-empty turn. `cardsRendered` is reported once, when the turn has products. |
| P5 | A failure reports `errorOccurred` and rethrows. Cancellation reports nothing. |
| P6 | Tap events (CTA/"Buy Now", product, link, suggestion) and `chatOpened`/`chatClosed` stay app-reported via `Concierge.track`. The SDK can't see those taps. |

## 4. SDK changes (beyond thin)

| File | Change |
| --- | --- |
| `Core/ConciergeTurn.swift` (new) | The assembler. Pure value type with no I/O. |
| `Core/ConciergeConversationCore.swift` | `sendTurn`, plus an injectable `dispatch` for tests. Both `send` and `sendTurn` share one internal `payloads(for:context:)`. |
| `Controllers/ChatController.swift` | The turn engine's local accumulators (`accumulatedContent`, `latestElements`, `responseStartedDispatched`) are replaced by one `ConciergeTurn`. Rendering, caps, recovery and the empty-response path are unchanged. |
| `Core/Concierge+Headless.swift` | Docs only: which events `sendTurn` reports. |

`ChatController` keeps dispatching its own turn events through its injected `dispatch`; it does not
call `sendTurn`. Its turn caps and background recovery wrap the raw stream, and moving them into
`sendTurn` is a larger change (see G4).

Validation: the full unit-test suite passes, including the existing `ChatController` stream,
handoff contract and tracking tests, which now exercise `ConciergeTurn` through the SDK UI. New
tests cover assembler semantics, automatic events and the empty-response error.

## 5. Customer responsibilities (what DSG writes)

The demo `HeadlessCoreChatView.swift` on `headless_plus` drops about 50 lines of accumulation and
tracking code compared with thin.

```swift
for try await turn in core.sendTurn(q) {
    messages[index].turn = turn            // render turn.text / .products / .ctaButtons / .promptSuggestions
}
// taps only:
Concierge.track(.ctaButtonClicked(label: cta.text, url: url))   // Buy Now
Concierge.track(.productClicked(element))
```

DSG still owns:

- the transcript and rendering;
- error copy and retry;
- tap analytics;
- welcome content;
- re-creating the core after an identity reset.

## 6. Gaps (in addition to thin G1–G9)

| # | Gap | Proposal |
| --- | --- | --- |
| PG1 | `sendTurn` has no no-response or wall-clock caps (thin G4). | Optional `TurnPolicy` parameter (timeouts) applied inside `sendTurn`. `ChatController` could later adopt it to delete its own caps. |
| PG2 | `ConciergeTurn` exposes raw wire models (`MultimodalElement`, `EntityInfo`), so wire changes leak to customers. | Accept for v1 because they are already public. Consider `ConciergeProduct` projections later, with no duplicate models in the SDK UI. |
| PG3 | Two event-dispatch paths (`ChatController.dispatchTrackingEvent`, `sendTurn`) can drift. | Contract test that asserts identical event sequences for the same planned chunks through both. |
| PG4 | `ConciergeTurn` is a value snapshot per chunk, so large transcripts copy arrays per update. | Fine at chat sizes; revisit only if profiling shows a problem. |

## 7. Server

No changes required. The same nice-to-haves as thin apply. An explicit end-of-turn event would
let `sendTurn` finish without waiting for the connection to close.

## 8. Android parity

`ConciergeTurn` is a data class with `apply(payload): Boolean`, and
`sendTurn(query): Flow<ConciergeTurn>` carries the same event list. P1/P2 must match
byte-for-byte on event names and data. Share the test vectors (planned chunks → expected turn and
events) between platforms.

## 9. Estimates (per platform)

| | Adobe | DSG |
| --- | --- | --- |
| Thin | 2–3 wks | 9–13 wks |
| **Plus (this spec)** | 3–4 wks | 7–10 wks |

The extra Adobe week covers the assembler, the `ChatController` adoption, cross-platform test
vectors and PG3.

## 10. Recommendation

Ship **plus**. It costs one more Adobe week per platform and saves DSG 2–3 weeks. More importantly,
it puts the analytics contract (the reason CTA reporting was hard to verify) inside the SDK instead
of in every customer UI.
