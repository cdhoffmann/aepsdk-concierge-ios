# Headless Concierge – Internal Spec (iOS)

> **Audience:** Adobe SDK engineers (iOS + Android). This is an internal document.
> **Public usage guide:** [headless.md](headless.md)
> **Tracking:** PLAT-320683
> **Branch:** `headless_plus`, rebased on `dev` (`fac89e1`)
> **Status:** POC is code-complete on iOS and the full unit suite passes (1081 tests). The code-review fixes are in: one live conversation per surface set pinned to its session, `.failed(error)`, `retry()`, close reasons, `Role.app`, one element classifier, and SSE buffering for headless. Android is on `rymorale/aepsdk-concierge-android@feature/headless`, and its alignment work is listed in §8.

---

## 1. Goal and constraints

**Goal:** Let an app (DSG first) build its own chat UI on top of the Concierge SDK. The SDK still owns transport, auth-token pass-through, session, analytics, feedback, data handoff, and identity reset.

**Constraints, in priority order:**

1. **Minimize changes to the SDK.** The UI path must behave exactly as it does today, and changes must be additive only.
2. **Support every current feature cleanly for headless.** This includes token pass-through, data handoff (Buy Now → checkout → reply), feedback, analytics, identity reset, and background recovery.
3. **Scale.** Each behavior lives in one place, so a fix lands once and the UI path and the headless path cannot drift.
4. **Align with Android.** Both platforms share the same public shape and the same behavior contract.

---

## 2. Architecture

### 2.1 Layers

```
                ┌─────────────────────────────┐      ┌──────────────────────────┐
   SDK UI  ───▶ │ ChatController (adapter)    │      │ App's own UI (headless)  │
                │  rows, native cards, speech,│      │  observes messages/state │
                │  welcome, scroll            │      │  calls send/track/...    │
                └──────────────┬──────────────┘      └────────────┬─────────────┘
                   presenter   │ ConciergeConversationPresenter    │ public API
                               ▼                                   ▼
                ┌──────────────────────────────────────────────────────────────┐
                │ ConciergeConversation  (public, @MainActor, ObservableObject)│
                │  turn engine: transcript, state, single-flight, caps,        │
                │  background recovery, turn analytics, feedback IDs,          │
                │  handoff target, identity reset                              │
                └──────────────────────────────┬───────────────────────────────┘
                                               ▼
                ┌──────────────────────────────────────────────────────────────┐
                │ ConciergeConversationCore (internal)                         │
                │  per-turn auth token, XDM context, session ID, SSE stream,   │
                │  feedback POST, cancel, identity end                         │
                └──────────────────────────────┬───────────────────────────────┘
                                               ▼
                                ConciergeChatService (SSE)  →  Concierge runtime
```

There is **one turn engine**, and it lives in `ConciergeConversation`. The SDK UI does not run its own engine. `ChatController` owns a `ConciergeConversation` and acts as a presenter over it.

### 2.2 Presenter hooks

`ConciergeConversationPresenter` (internal) is how the UI adapter projects engine events into its own view state. Its hooks are:

- the user's message was accepted (the UI adds its row and shares the ID with `messages`)
- the turn started
- a chunk was applied
- the turn completed, with a render plan
- the response was discarded
- the turn failed
- the render plan for a payload

A headless conversation has no presenter, so the engine falls back to its defaults: `ConciergeElementPlan` and no UI side effects.

### 2.3 Render plans

`ConciergeRenderPlan` (internal protocol) decides how a completed payload becomes elements, and which `cardsRendered` event (if any) to report.

| Plan | Used by | Output |
|---|---|---|
| `ResponseElementPlan` | SDK UI | Native card and carousel rows, as today |
| `ConciergeElementPlan` | Headless | `[ConciergeElement]` on `ConciergeMessage.elements` |

Because both paths use the same plan protocol, `cardsRendered` is reported identically for the UI and for headless.

### 2.4 Live conversations and handoff routing

`ConciergeActiveConversation` (internal) tracks the live conversations, headless or the SDK UI's. It holds **weak** references, so a conversation the app drops is not kept alive.

- **One live conversation per surface set** (compared as a set, like `hasSameChatServiceIdentity`). Activating a conversation on surfaces that already have one closes the previous one with `.closed(.replaced)` and releases its transport. Conversations on different surfaces coexist, as two SDK chats on different surfaces do today.
- **Who activates:** `Concierge.conversation(surfaces:)`, and the production `ChatController` init (the SDK UI). A UI session that is reused (`prepareSession`) is not reactivated.
- **All conversations share the app's one backend session.** `SessionManager` is app-wide, as in `dev`. Each conversation pins the session ID at creation (§4.7).
- **`Concierge.sendDataHandoff`** is unchanged as public API. It goes to the live conversation most recently opened or used: activation, and every typed turn or retry, mark it. If that conversation's session expired, it closes (`.sessionExpired`) and the handoff fails with `noActiveSession`. With no live conversation, it fails with `noActiveSession`. Handoffs carry no surface, so they can't be routed by surface.

### 2.5 Identity reset

`Concierge` builds the reset analytics from the UI controllers and the live headless conversations together:

- `hadActiveTurn` comes from `isResponding`.
- `hadConversation` is true when `messages` is non-empty.
- `conversationId` is the fallback ID.

It then ends the UI controllers and calls `endForIdentityReset()` on every live headless conversation. Each moves to `.closed(.identityReset)` and clears `messages`, because its configuration holds the stale ECID. The app must create a new one.

---

## 3. Public API

```swift
public extension Concierge {
    /// Validates configuration for `surfaces` (waits for Edge Identity), resumes the persisted
    /// backend session if active (or starts one), reports `sessionInitialized`, and makes the
    /// conversation live for its surfaces, closing the previous one on those surfaces (`.replaced`).
    @MainActor static func conversation(surfaces: [String]) async throws -> ConciergeConversation
    // throws ConciergeError.configurationUnavailable
}

@MainActor public final class ConciergeConversation: ObservableObject {
    @Published public private(set) var messages: [ConciergeMessage]
    @Published public private(set) var state: ConciergeConversationState
    public var configuration: ConciergeConfiguration { get }
    public var sessionId: String { get }                   // pinned for the conversation's life

    @discardableResult public func send(_ text: String) -> ConciergeSendResult
    @discardableResult public func retry() -> ConciergeSendResult   // resends the failed typed message
    public func cancel()                                   // keeps partial text
    public func sendFeedback(messageId: String, _ feedback: ConciergeFeedback)
    public func track(_ interaction: ConciergeInteraction)
    public func close()                                    // → .closed(.closedByApp)
}

public enum ConciergeConversationState: Equatable {
    case idle, responding
    case failed(ConciergeError)
    case closed(ConciergeCloseReason)
    public var isClosed: Bool { get }
}
public enum ConciergeCloseReason: Equatable { case closedByApp, replaced, sessionExpired, identityReset }
public enum ConciergeSendResult: Equatable {
    case accepted, blank, inProgress, closed, resetPending, nothingToRetry
}

public struct ConciergeMessage: Identifiable {
    public enum Role: Equatable { case user, agent, app }  // app = a handoff's localMessage
    public let id: String
    public let role: Role
    public internal(set) var text: String
    public internal(set) var isStreaming: Bool
    public internal(set) var elements: [ConciergeElement]
    public internal(set) var sources: [Source]
    public internal(set) var linkHints: [LinkHint]
    public internal(set) var promptSuggestions: [String]
    public internal(set) var feedbackEnabled: Bool
    public internal(set) var feedback: FeedbackSentiment?
}

public enum ConciergeElement {
    case productCard(ConciergeProductCard)
    case ctaButton(label: String, url: String?, raw: MultimodalElement)   // text-only CTAs are valid
    case custom(rendererId: String, raw: MultimodalElement)
    case unknown(type: String?, raw: MultimodalElement)   // malformed: custom without rendererId, CTA without action
    public var raw: MultimodalElement { get }
}

public struct ConciergeProductCard {   // flattened projection + raw
    id, productName, productDescription, description, productPageURL, productImageURL,
    productPrice, productWasPrice, productBadge, primary: ActionButton?, secondary: ActionButton?,
    raw: MultimodalElement
}

public struct ConciergeFeedback {
    public var sentiment: FeedbackSentiment
    public var categories: [String]
    public var notes: String
}

public enum ConciergeInteraction {
    case opened, closed
    case promptSuggestionClicked(String)
    case ctaClicked(label: String, url: String?)
    case productCardClicked(ConciergeProductCard)
    case productActionClicked(ConciergeProductCard, ActionButton)
    case sourceClicked(Source)
    case linkClicked(url: String)
    case linkHintClicked(LinkHint)       // → linkClicked, origin LINK_HINT
}

public enum ConciergeError: Error, Equatable { …existing…, case configurationUnavailable, case httpStatus(Int) }  // now public
```

**Element classification** is one rule set, `MultimodalElement.kind`, shared by the UI's `ResponseElementResolver` and `ConciergeElement`. So headless sees exactly what the UI would render:
- `type == "custom"` with a non-blank `rendererId` → `.custom`; blank → `.unknown`
- `type == "ctaButton"` with `entityInfo.primary` → `.ctaButton`; without → `.unknown`
- anything else → `.productCard`, including elements without `entityInfo` or with an unrecognized type

**Unchanged public API:** `Concierge.sendDataHandoff`, `setAuthTokenProvider`, `updateXDMContext`, and `show`/`present`/`wrap`.

**Reused public wire types:** `Source`, `LinkHint`, `ActionButton`, `FeedbackSentiment`, `MultimodalElement` (as `raw`).

**Not public:**
- `ConciergeConversationCore`, `ConciergeTurn`, `ChatTurn`
- the presenter, the render plans, `ConciergeActiveConversation`
- `ConversationPayload` and the rest of the wire models

---

## 4. Behavior contract

These are the behaviors that both platforms must match. Each row is covered by `ConciergeConversationTests` (§9).

### 4.1 Send / cancel / failure

| Case | Behavior |
|---|---|
| `send` blank text | `.blank`. No message is appended and no event is reported. |
| `send` while `responding` | `.inProgress`. The send is dropped. |
| `send` after `close()`, replacement or identity reset | `.closed`. While an identity reset is still in flight: `.resetPending`. |
| `send` after the pinned session expired | The conversation closes with `.sessionExpired` and `send` returns `.closed`. No request is made (§4.7). |
| `send` accepted | Appends a user message and an empty, streaming agent message. State becomes `responding` and the SDK reports `querySubmitted`. |
| Chunks | Update `text` and `isStreaming` in place on the agent message. The first chunk reports `responseStarted`. |
| Complete | Fills `elements`, `sources`, `linkHints`, `promptSuggestions`, and `feedbackEnabled`. The SDK reports `responseCompleted` and `cardsRendered` (if cards are present). State becomes `idle`. |
| Empty response (no text, no renderable elements) | The agent message is removed. For a typed turn the SDK reports `errorOccurred`. State becomes `failed(.invalidResponseData)`. |
| Transport error | The agent message is removed and the SDK reports `errorOccurred`. State becomes `failed(error)`, carrying the `ConciergeError`. |
| Non-2xx HTTP status | The service logs the code and cancels before reading the body. Handled as a transport error with `failed(.httpStatus(code))`, for typed turns and handoffs; `errorOccurred` carries the code. Not resent in the background (only `.timeout`/`.unreachable` are); the app can `retry()`. |
| `retry()` after a failed typed turn | Resends the same text **without** appending another user message. Reports `querySubmitted` again. Returns `.accepted`. |
| `retry()` otherwise | `.nothingToRetry` (not failed, or the failed turn was a handoff). Admission refusals (`.closed`, `.inProgress`, `.resetPending`) take precedence. |
| `cancel()` | Stops the stream and keeps the partial text. `isStreaming` becomes `false` and state becomes `idle`. |

### 4.2 Background recovery

The engine observes `ConciergeAppState`. Recovery applies when a **typed** turn fails because the app went to the background mid-stream, and it applies to both the UI and headless:

- The SDK discards the partial response, waits for the app to return to the foreground, and resends **once**. The resend has a new interaction ID, so it reports its own `responseStarted`/`responseCompleted`.
- It is skipped when the session TTL (`backgroundRecoveryMaxAge`) has passed. In that case the SDK reports `errorOccurred` and state becomes `failed`.
- It never applies to handoff turns, and the resend itself is not retried.

> **Divergence:** Android currently documents recovery as "not supported" for headless.

### 4.3 Data handoff

| Case | Behavior |
|---|---|
| Routing | Goes to the live conversation most recently opened or used (§2.4). |
| Target's session expired | The target closes with `.sessionExpired`; the handoff fails with `noActiveSession`. |
| Target is `responding` | Rejected with `chatInProgress`. |
| No target (all closed, reset, or none) | Rejected with `noActiveSession`. |
| Accepted | Appends the `localMessage` (if any) as a `Role.app` message, then streams the reply into `messages` like a typed turn. |
| No response within **10 s** | The response is removed and `localMessage` is kept. State becomes `failed(.timeout)` and the caller gets `.timeout`. `retry()` does not resend handoffs. |
| Wall-clock ceiling **60 s** | Armed at admission, so it also covers the auth-token wait. Same unwind as the 10 s case. |
| Deadline timeout | Not reported as `errorOccurred`. The caller's completion is the signal. |
| `cancel()` during a handoff | The caller gets `deliveryFailed`. |

### 4.4 Auth token

- `setAuthTokenProvider` is called **once per turn**, before the request is sent, with a **3 s** timeout.
- A `nil` result or a timeout sends the turn without a token. The turn is not failed.
- The token goes into the request body as `conversation.data: [{ "type": "auth", "payload": { "token": "<token>" } }]`.
- The runtime converts this into the A2A secure-context data part. The SDK does **not** build the A2A part.

### 4.5 Analytics

**Reported automatically by the SDK, identically for the UI and headless:**
- `sessionInitialized` (at `conversation(surfaces:)`)
- `querySubmitted`, `responseStarted`, `responseCompleted`
- `cardsRendered`
- `errorOccurred`
- feedback events
- identity-reset events

**Reported by the app through `track(_:)`:** every interaction listed in `ConciergeInteraction`. Each case maps to the same `ConciergeTrackingEvent` the SDK UI emits, with the same origin values. For example, `ctaClicked` → *CTA Button Clicked* + *Link Clicked*.

**Owned entirely by the app (no SDK event exists):** analytics for UI the app builds itself, such as the welcome prompt, mic/speech, the disclaimer, and privacy-notice links. This is a deliberate decision, and the public guide lists these items.

### 4.6 Feedback

- `sendFeedback(messageId:)` resolves the backend interaction ID from the engine's `feedbackIds` map, so the app never handles backend IDs.
- Feedback is accepted only when `feedbackEnabled == true`. On iOS, CTA-only responses are eligible.
- The call sets `message.feedback`.

### 4.7 Session and lifecycle

| Case | Behavior |
|---|---|
| Creation | Resumes the persisted backend session if it is still within its TTL, otherwise starts a new one. The ID is pinned: every turn and feedback request of this conversation uses it, and `sessionId` never changes. |
| Session expires (30 min idle, or cleared) | Checked lazily on `send`, `retry`, and handoff routing. The conversation closes with `.sessionExpired`; it never moves to another session. The app creates a new conversation. |
| Explicit `_sessionId` in configuration (tests) | The expiry check is skipped. |
| SDK UI, mid-chat expiry | The controller closes the expired conversation, creates a new one on a new session, and keeps the visual transcript, as `dev` does. |
| Replaced (same surfaces) | `.closed(.replaced)`; the in-flight turn is cancelled and the transport is released. |
| `close()` / any close | Cancels the turn, invalidates the `URLSession` (feedback in flight may finish), and leaves the live set. |

### 4.8 Streaming

Headless conversations always use buffered SSE framing (lines are reassembled across network chunks). The SDK UI keeps `dev`'s behavior: buffered only when a native card renderer is registered (PR #197). Making buffering universal is post-POC (§10).

---

## 5. Reasoning and alternatives

### 5.1 SDK-owned transcript vs per-turn streams (the old "Thin" option)

**Rejected:** a per-turn `AsyncStream` API (`sendTurn`) where the app owns the transcript.

**Chosen:** `ConciergeConversation` owns `messages`. The reasons:

- **Handoff replies need somewhere to land.** In the Buy Now flow (Buy Now → native checkout → `sendDataHandoff` → reply), the handoff is global and has no caller stream to return to. With an SDK-owned transcript, the reply goes into `messages`.
- **Feedback by message ID.** The app never sees backend interaction IDs.
- **Self-contained identity reset.** The SDK can close the conversation and report reset analytics from its own state.
- **Explicit state removes a class of bugs.** A single `state` property drives the Stop button and the loader, which closes off the "Stop button leaves the loader running" class of bug that we hit.
- **Android chose the same shape,** so both platforms share one public contract.

### 5.2 One engine vs a parallel headless engine

**Rejected:** a headless engine that sits beside `ChatController`'s engine. Android currently has this: the logic is duplicated in its view model (~2300 lines) and its conversation class (~585 lines), and the two copies have already drifted on caps, the empty-response path, and feedback eligibility.

**Chosen:** the engine is moved out of `ChatController` into `ConciergeConversation`, and `ChatController` becomes an adapter over it. The cost was a one-time refactor (`ChatController` −728/+…). After that:

- every fix (caps, recovery, analytics) lands once
- the UI path exercises the headless engine on every turn
- the existing ~1000 UI tests now also guard headless

### 5.3 Global handoff entry point

The existing `Concierge.sendDataHandoff` is kept as the only entry point, and the target is the live conversation most recently opened or used. No new public API is needed. Checkout code also stays the same whether the SDK UI or the headless UI is on screen.

**Rejected:** `conversation.sendDataHandoff`. It forces checkout code to know about the conversation instance, and it duplicates the API.

### 5.4 Projections with `raw`

`ConciergeElement` and `ConciergeProductCard` are stable, flattened projections. Each also carries `raw: MultimodalElement` for fields the projection does not cover yet. This keeps `ConversationPayload` and the other wire models internal, so the backend schema can evolve without breaking the public API.

### 5.5 Validate configuration at creation

`conversation(surfaces:)` is `async throws`. It waits for Edge Identity and resolves the configuration up front. The alternative was to fail at the first `send`. Up-front validation means:

- an app finds out about misconfiguration before it draws a chat UI
- surfaces are per conversation, not global

### 5.6 One live conversation per surface set, pinned to its session

**Chosen:** a conversation maps 1:1 to the backend session it was created on, and only one is live per surface set. Its owner (SDK UI or app) doesn't matter.

- **No silent session moves.** Before, a conversation re-resolved the session per turn, so after expiry its transcript stayed on screen while turns went to a new backend session with no context. Now it closes with a reason, and the app decides what to show.
- **Handoffs can't land in a forgotten conversation.** Same-surface duplicates are closed, so the routing target is always a live, recently used one.
- **Different surfaces keep coexisting.** Apps use surfaces to create distinct chats (ex: a "shop" overlay and a "help" tab). `dev` supports both being usable at once, so this is kept. They share the backend session, as in `dev`.

**Rejected:** one live conversation app-wide. It disabled a second chat on other surfaces, which `dev` supports. **Rejected:** a backend session per surface set. That's a behavior change from `dev`, and needs backend verification.

### 5.7 `send` returns a result

Silent drops (blank text, in progress, closed) were the main debugging complaint during the POC, so `send` returns `ConciergeSendResult`. It is `@discardableResult`, so callers that don't care can ignore it.

---

## 6. SDK changes

These are all relative to `dev`. Changes are additive for public API, and the UI behavior is unchanged apart from §11.

| File | Change |
|---|---|
| `Core/ConciergeConversation.swift` (new) | Public conversation, turn engine, `retry`, close reasons, presenter protocol, render plans, `ConciergeActiveConversation` |
| `Core/ConciergeMessage.swift` (new) | Public message, element, product card, feedback, state, close reason, send result, interaction |
| `Core/ConciergeConversationCore.swift` (new, internal) | Transport wrapper (token, XDM, pinned session, expiry, stream, feedback, cancel, close) |
| `Core/ConciergeTurn.swift` (new, internal) | Chunk/payload assembly shared by both paths |
| `Core/Concierge+Headless.swift` (new) | `conversation(surfaces:)` factory |
| `Controllers/ChatController.swift` | Engine removed; the presenter adapter remains. Sends, opened/closed and CTA tracking go through the conversation. Renews its conversation on session expiry. |
| `Controllers/ChatTurn.swift` | Turn kinds, caps, and recovery reservation, used by the engine |
| `Controllers/ResponseElementResolver.swift` | `MultimodalElement.kind`: the one element classifier |
| `Core/Concierge.swift` | Identity reset and handoff routing over the live conversations |
| `Core/Concierge+PublicAPI.swift`, `Presentation/ConciergeChatSession.swift` | A UI session's ID is its conversation's pinned session; a closed conversation is never reused |
| `Core/ConciergeTrackingEvent.swift` | `linkHintClicked` origin; interaction → event mapping; CTA without URL |
| `Models/Network/ConciergeError.swift` | Made public and `Equatable`; `configurationUnavailable` and `httpStatus(Int)` added |
| `Services/ConciergeChatService.swift` | `buffersSSEFrames` (headless), `invalidate()`; chat requests check the HTTP status in `didReceive response`, log it, and fail with `httpStatus(code)` |
| `ConciergeXDMContextStore.swift`, `ConversationPayload.swift`, `ConciergeDataHandoffEvent.swift`, `ConciergeConfiguration.swift` | Small internal seams |

**Code shared between the UI and headless:**
- the turn engine
- chunk/payload assembly
- caps and recovery
- analytics mapping
- feedback
- handoff
- identity reset

**Code that stays UI-only:**
- row models
- native card views
- speech
- welcome/disclaimer
- scroll
- theme

---

## 7. Alternatives not pursued

- **Make `ChatController` public.** Rejected: it is SwiftUI-shaped and full of UI state.
- **A delegate or callback API instead of `ObservableObject`.** Deferred: Combine/SwiftUI covers DSG. A UIKit-friendly `AsyncStream` accessor is on the post-POC list.
- **Queued handoffs.** Rejected for now: single-flight rejection with `chatInProgress` matches the UI. This is open question S13.

---

## 8. Android alignment

### 8.1 Asks for Android

1. **Move the VM onto `ConciergeConversation`** so that Android has one engine. This is the biggest item.
2. **Per-conversation surfaces,** with configuration validated at creation.
3. **Report `sessionInitialized` at creation** (decision D4).
4. **Live conversations per surface set (§2.4, §5.6).** `ActiveConciergeDataHandoffForwarder` is one slot and doesn't close what it replaces. Key it by surface set, close a same-surface predecessor with `replaced`, and route handoffs to the most recently opened or used.
5. **Pin the session (§4.7)** and close with `sessionExpired` instead of moving sessions.
6. **API parity:** `failed(error)`, close reasons, `retry()`, `Role.APP` for `localMessage`, optional CTA URL, one element classifier shared with the UI, buffered SSE for headless.

### 8.2 Known divergences (to resolve or accept)

| # | Topic | iOS | Android | Proposal |
|---|---|---|---|---|
| 1 | Identity reset | Conversation → `closed`; the app creates a new one | Clears and stays usable | iOS: config holds the stale ECID. Android should match. |
| 2 | `send` return | `ConciergeSendResult` | `Unit` | Android adds the result |
| 3 | Wire types | Reuses `Source`, `FeedbackSentiment`, `ActionButton` | Headless-specific copies | Platform choice; accept |
| 4 | `cardsRendered` | Automatic | App-tracked | Android goes automatic |
| 5 | Feedback on CTA-only responses (S6) | Eligible | Suppressed | Align with the UI behavior on each platform; confirm with product |
| 6 | Fallback conversation ID (S7) | `"unknown"` | `""` | Pick one |
| 7 | Link hints | `linkHints` + `linkHintClicked` | Not exposed | Android adds them |
| 8 | Background recovery | In the engine; applies to headless | "Not supported" | Falls out of the Android engine unification |
| 9 | Live conversations | One per surface set; same-surface replace closes the old one (`replaced`) | One forwarder slot; the old conversation stays usable | Android matches iOS (§8.1 #4) |
| 10 | Session | Pinned at creation; closes on expiry | Re-resolved per turn | Android matches iOS |
| 11 | Failure / close detail | `failed(ConciergeError)`, `closed(reason)`, `retry()` | `Failed`, `Closed`, no retry | Android matches iOS |
| 12 | HTTP status errors | `httpStatus(code)`; checked in `didReceive response` | `ConciergeHttpStatusException` → `INVALID_RESPONSE_DATA` | Android maps to `httpStatus(code)` |

---

## 9. Validation

- **Full unit suite:** 1081/1081 passed (iOS 18 simulator) after the code-review fixes.
- **`ConciergeConversationTests` (21 tests):**
  - send, rejection, failure, empty response, cancel
  - feedback
  - track (including the `linkHintClicked` origin)
  - handoff: `localMessage`, in-progress rejection, the 10 s silent-service timeout, and the ceiling covering the token wait
  - identity reset, close (cancels, releases the transport, leaves the live set)
  - same-surface replacement; different surfaces coexist and handoffs follow the last used
  - pinned session closes on expiry
  - `retry` (no duplicate message, `nothingToRetry`), `failed(error)`, `Role.app`
  - turn assembly, element classification matching the UI, CTA without URL
- **`ConciergeChatServiceTests`:** buffered framing reassembles split lines for headless without renderers.
- **`ConciergeTests`:** handoff routing to a headless-only conversation.
- **Demo app:** Testing Hub → *Headless* shows a custom SwiftUI transcript on `ConciergeConversation`. With "Use Buy Now mock responses" on, tapping Buy Now → checkout sheet → handoff streams the reply into the headless transcript.

Commands:

```bash
xcodebuild build-for-testing -workspace AEPBrandConcierge.xcworkspace -scheme UnitTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath build/out ADB_SKIP_LINT=YES -quiet
xcodebuild test-without-building -workspace AEPBrandConcierge.xcworkspace -scheme UnitTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath build/out \
  [-only-testing:UnitTests/ConciergeConversationTests]
```

---

## 10. Post-POC work to reach production

Sizing is rough, for one engineer per platform.

### 10.1 Must-have

| # | Item | Why | Size |
|---|---|---|---|
| G2 | Universal SSE buffering | Headless already buffers (§4.8). The SDK UI still uses the legacy framing unless a native card renderer is registered, so a `data:` line split across network chunks can be dropped there. Make buffering universal after a UI regression pass. | S |
| f5 | Consent read per request | Consent is captured when a conversation is created. A user who opts out mid-conversation still sends with the old value until a new one is created. Existing UI behavior, but headless conversations live longer. Read consent per request through a store updated on Consent shared-state changes; needs a privacy review. | M |
| G3 | HTTP status mapping (401/429/5xx → typed errors) | **Done on iOS:** `httpStatus(code)` lets apps tell auth failures, throttling and outages apart. Remaining: Android parity (§8.2 #12) | S |
| G6 | `ConciergeError` evolution | Now public, so adding cases breaks exhaustive `switch`. Document `@unknown default`, or freeze the enum and add a `code`. | S |
| — | Typed-turn timeout policy | Only handoff turns have caps. A hung typed turn stays `responding` until the user cancels. Decide whether to apply a ceiling. | S |
| — | API review and `@unknown` / `Sendable` audit | `@MainActor` types, `Sendable` conformance on value types, public `init`s for test doubles | S–M |
| — | Shared contract test vectors | The §4 rows expressed as JSON fixtures (chunks in, messages/events out), run on both platforms to prevent drift | M |
| — | Android engine unification (§8.1) | Without it, Android keeps two drifting engines | L (Android) |
| — | Resolve §8.2 divergences | One behavior contract | S each |
| — | Public docs | Finish `headless.md`, port `headless-styling.md`, fix the stale `{ accepted, rejectReason in }` example in `implementation-guide.md` | S |

### 10.2 Should-have

| # | Item | Notes | Size |
|---|---|---|---|
| G7 | Welcome, disclaimer, and feedback categories are theme-only | Expose them on `configuration` so headless apps can render them without parsing the theme | S–M |
| — | `AsyncStream` accessors for `messages`/`state` | For UIKit and non-Combine apps | S |
| S13 | Handoff queue vs single-flight | Decide whether a handoff during a turn should wait instead of being rejected | S |
| f8 | One transcript in UI mode | The UI's row array and `conversation.messages` are both updated per chunk. Make the rows a projection of `conversation.messages`, with welcome, native-card and suggestion rows layered on top. Approved for the POC but not done yet: it is the next commit. | M |
| f10 | Test double / previews | Apps can't build previews or unit tests without a live SDK. Add `ConciergeConversation.preview(messages:state:)` with a no-op transport, or a public protocol; decide at API freeze. | S–M |
| — | Feedback through the conversation in UI mode | The UI still submits feedback with the payload IDs on its rows (this keeps feedback working on rows from before a session renewal). Route through `sendFeedback` once f8 lands. | S |
| — | Same surfaces, different title | The UI treats a title change as a new chat; with one live conversation per surface set, two UI chats on the same surfaces but different titles replace each other. Decide whether the title is part of the key. | XS |

### 10.3 Later

| # | Item | Notes | Size |
|---|---|---|---|
| G8 | Module split (`AEPBrandConciergeCore` without SwiftUI views) | Binary size for headless-only apps; not a functional need | M–L |
| — | Speech helper | Speech is app-owned today; a thin optional helper could be offered | M |

**Release plan:** ship as an additive minor release on both platforms at the same time, with the headless API documented in `headless.md`. There is no runtime or backend change.

---

## 11. Migration

No code changes required. The public symbols are additive, and `ConciergeError` is newly public, which does not break source compatibility.

**Behavior change for existing `show`/`present` apps:** two SDK chats that are on screen at the same time on the **same surfaces** but with different titles or subtitles no longer both stay usable. Opening the second closes the first (its composer is disabled). Chats on the same surfaces and title already share one controller, and chats on different surfaces are unaffected. After an identity reset, the same rule applies when the overlay and UIKit chats are restored.
