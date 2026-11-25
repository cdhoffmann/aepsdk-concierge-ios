# Headless conversations

`Concierge.conversation(surfaces:)` starts a Brand Concierge conversation with no UI. Use it when the app draws its own chat. The conversation sends messages, streams responses, sends feedback and reports analytics. The app draws every message and decides what each tap does.

A headless conversation is part of the Brand Concierge extension. It uses the same setup as the built-in chat UI and shares its state:

- The configuration, and the session ID.
- Identities from Edge Identity, and consent.
- The auth token from `Concierge.setAuthTokenProvider`.
- The XDM context from `Concierge.updateXDMContext`.
- Analytics settings from `Concierge.setEdgeTrackingEnabled`.

Set up the extension as described in the [Implementation Guide](implementation-guide.md#configuration). No other dependency is needed.

## Start a conversation

```swift
@MainActor
final class ChatModel: ObservableObject {
    @Published var conversation: ConciergeConversation?

    func open() async {
        do {
            let conversation = try await Concierge.conversation(surfaces: ["web://example.com/index.html"])
            conversation.track(.opened)
            self.conversation = conversation
        } catch {
            // ConciergeError.configurationUnavailable: the extension isn't ready (ex: Edge Identity
            // hasn't resolved yet, or identities are being reset). Retry later.
        }
    }

    func dismiss() {
        conversation?.track(.closed)
        conversation?.close()
    }
}
```

`Concierge.conversation(surfaces:)` returns a `ConciergeConversation`. It is `@MainActor`; call its methods on the main actor. It resolves configuration the same way `Concierge.show(surfaces:)` does and throws `ConciergeError.configurationUnavailable` if it can't, so a bad setup shows up here rather than on the first message.

Each conversation keeps its own surfaces. Call `close()` when you no longer need it. After `close()`, `state` is `.closed(.closedByApp)` and the conversation ignores new messages.

### One live conversation per surface set

Only one conversation is live for a given set of surfaces. Opening a new conversation on the same surfaces, or opening the built-in chat on them, closes the previous one with `.closed(.replaced)`. Conversations on different surfaces stay live side by side.

### Session

A conversation continues the current Brand Concierge session if it is still active, or starts a new one, and stays on that session (`sessionId`) for its whole life. A session expires after 30 minutes without a message. After that, the next `send` closes the conversation with `.closed(.sessionExpired)` and returns `.closed`. Create a new conversation to continue; you can keep showing the old messages.

## Send messages

```swift
let result = conversation.send("What running shoes do you have?")
```

`send` adds a user message, then streams the agent's reply. `ConciergeConversation` is an `ObservableObject`; observe `messages` and `state` to draw the chat:

```swift
struct ChatView: View {
    @ObservedObject var conversation: ConciergeConversation

    var body: some View {
        List(conversation.messages) { message in MessageRow(message: message) }
        if conversation.state == .responding { ProgressView() }
        if case .failed(let error) = conversation.state {
            Button("Retry") { conversation.retry() }   // ex: show `error` too
        }
    }
}
```

`messages` holds every `ConciergeMessage`, oldest first:

| Property | Meaning |
| --- | --- |
| `id` | Identifies the message. Use it as a list key and for feedback. |
| `role` | `.user`, `.agent`, or `.app` (a data handoff's `localMessage`). |
| `text` | The message text, which can contain Markdown. While `isStreaming` is true, it holds the text received so far. |
| `isStreaming` | True while the agent is still writing this message. |
| `elements` | Product cards, CTA buttons and other elements, in response order. Set when the response completes. |
| `sources` | Citations. `startIndex` and `endIndex` locate the cited text. |
| `linkHints` | Links in `text` with a kind (ex: `"phone"`, `"store"`), so the app can style them. |
| `promptSuggestions` | Follow-up prompts the user can send. |
| `feedbackEnabled` | True when the message can receive feedback. |
| `feedback` | The rating sent for this message, or `nil`. |

`state` is one of:

| State | Meaning |
| --- | --- |
| `.idle` | Ready to send. |
| `.responding` | Waiting for or receiving a reply. Show a loading indicator until the agent message appears. |
| `.failed(ConciergeError)` | The last reply failed, with the reason (ex: `.timeout`, `.unreachable`, or `.httpStatus(401)` when the service rejects the request). Its agent message is removed and the user message stays. The user can send again, or `retry()`. |
| `.closed(ConciergeCloseReason)` | The conversation ended: `.closedByApp`, `.replaced`, `.sessionExpired` or `.identityReset`. Use `state.isClosed` to check for any reason. |

Only one reply runs at a time; messages are not queued. `send` returns a `ConciergeSendResult` you can ignore or use to explain why nothing happened:

| Result | Meaning |
| --- | --- |
| `.accepted` | The message was added and the reply started. |
| `.blank` | The text was empty or whitespace. |
| `.inProgress` | A reply is already running. |
| `.closed` | The conversation is closed. |
| `.resetPending` | Identities are being reset. |
| `.nothingToRetry` | Only from `retry()`: there is no failed message to resend. |

Call `retry()` after a failed reply to resend the same message without adding it to `messages` again. Data handoffs are not retried.

Call `cancel()` to stop a reply. The text received so far stays in `messages`.

If the app is backgrounded mid-reply and the connection drops, the conversation resends the message once when the app returns to the foreground, like the built-in UI.

## Elements

Each agent message's `elements` are `ConciergeElement` values:

| Element | Contents |
| --- | --- |
| `.productCard(ConciergeProductCard)` | Product name, descriptions, page and image URLs, price, was-price, badge, and primary and secondary `ActionButton`s. |
| `.ctaButton(label:url:raw:)` | A label and an optional URL. A CTA without a URL is valid. |
| `.custom(rendererId:raw:)` | A `custom` element with a `rendererId`, for your own renderer. |
| `.unknown(type:raw:)` | A malformed element the built-in UI would not show (ex: a `custom` element without a `rendererId`). |

Elements are classified exactly as the built-in UI renders them. Any element that is not `custom` or `ctaButton` is a product card.

Every element keeps the element exactly as received in `raw`, for fields the types do not model.

## Feedback

When `feedbackEnabled` is true, send the user's rating with the message ID:

```swift
conversation.sendFeedback(messageId: message.id,
                          ConciergeFeedback(sentiment: .positive, categories: ["Helpful"]))
```

The message's `feedback` changes to the rating. A message is eligible when the service marks the response eligible.

## Analytics

The conversation reports its own events: session initialized, query submitted, response started and completed, cards rendered, errors and feedback. Report the user's taps with `track`. Each interaction sends the same events as the built-in UI:

| Interaction | When |
| --- | --- |
| `.opened`, `.closed` | The chat is shown or hidden. `.closed` reports the time since `.opened`. |
| `.promptSuggestionClicked` | A prompt suggestion is tapped. |
| `.ctaClicked` | A CTA button (ex: **Buy Now**) is tapped. |
| `.productCardClicked` | A product card is tapped. |
| `.productActionClicked` | A product card button is tapped. |
| `.sourceClicked` | A citation is tapped. |
| `.linkClicked` | A link in the message text is tapped. |
| `.linkHintClicked` | A link in the message text that has a `LinkHint` is tapped. |

`track` only reports. Your app opens the link or sends the suggestion:

```swift
func handle(_ interaction: ConciergeInteraction) {
    conversation.track(interaction)
    switch interaction {
    case .promptSuggestionClicked(let suggestion): conversation.send(suggestion)
    case .ctaClicked(_, let url): url.map(open)
    case .productCardClicked(let card): card.productPageURL.map(open)
    case .productActionClicked(_, let action): action.url.map(open)
    case .sourceClicked(let source): open(source.url)
    case .linkClicked(let url): open(url)
    case .linkHintClicked(let hint): open(hint.href)
    case .opened, .closed: break
    }
}
```

Events are forwarded to Edge only after `Concierge.setEdgeTrackingEnabled(enable: true)`. Tracking is off by default.

Links come from the service. Before opening one, check its scheme.

## Identity reset

When identities are reset, the conversation stops any reply in progress, clears its messages and closes (`state` becomes `.closed(.identityReset)`), like the built-in UI. Create a new conversation once the extension is ready again.

## Data handoff

While a conversation is open, [`Concierge.sendDataHandoff`](implementation-guide.md#data-handoff) delivers to it. There is no separate headless API:

```swift
Concierge.sendDataHandoff(
    routingHint: "successful-checkout",
    xdmFields: ["commerce": ["order": ["purchaseID": orderId]]],
    localMessage: "Your order is confirmed!"
) { result in }
```

- `localMessage`, if set, is added to `messages` as an `.app` message, because neither the user nor the agent wrote it. The response then streams in like a reply to `send`, and `state` is `.responding` until it finishes.
- The handoff fails with `chatInProgress` while a reply is in progress, and with `noActiveSession` after `close()`, during an identity reset, or when the session has expired.
- If the handoff fails or times out, the response is removed, `localMessage` stays, and `state` is `.failed(error)`. `cancel()` stops it and reports `deliveryFailed`.
- Only one chat receives handoffs: the live conversation or built-in chat most recently opened or used.

## Not yet supported

- Speech input and read-aloud. Use the platform speech APIs.
- Welcome content, disclaimer and feedback categories from the theme JSON. Hard-code them or load them from your own CMS.

## Sample

The demo app's Testing Hub **Headless** scenario (`ConciergeDemoApp/HeadlessCoreChatView.swift`) is a complete example. It streams replies, shows product cards, CTAs, sources and suggestions, sends feedback, reports taps and stops replies. With **Use Buy Now mock responses** on, tap a product's **Buy Now** and complete the checkout sheet; the demo calls `Concierge.sendDataHandoff`, and the agent replies in the same chat.
