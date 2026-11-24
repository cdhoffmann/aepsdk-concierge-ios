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

import SwiftUI
import AEPBrandConcierge

/// Headless POC: a chat UI the *app* owns, built only on the public `ConciergeConversation`. The
/// SDK runs turns, keeps the transcript in `messages` and reports turn analytics; the app renders
/// and reports taps with `track(_:)`. Checkout handoffs arrive through `Concierge.sendDataHandoff`.
struct HeadlessCoreChatView: View {
    let surfaces: [String]
    @Binding var useMockResponses: Bool
    var handleLink: (URL) -> Bool

    @StateObject private var loader = HeadlessConversationLoader()

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Use Buy Now mock responses", isOn: $useMockResponses)
                .font(.footnote)
                .padding(.horizontal)
            Divider()
            switch loader.loadState {
            case .loading:
                ProgressView().frame(maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Retry") { Task { await loader.load(surfaces: surfaces) } }
                }
                .padding()
                .frame(maxHeight: .infinity)
            case .ready(let conversation):
                HeadlessTranscriptView(conversation: conversation, handleLink: handleLink,
                                       reload: { Task { await loader.load(surfaces: surfaces) } })
            }
        }
        .task { await loader.load(surfaces: surfaces) }
    }
}

@MainActor
final class HeadlessConversationLoader: ObservableObject {
    enum LoadState { case loading, ready(ConciergeConversation), failed(String) }

    @Published private(set) var loadState: LoadState = .loading

    func load(surfaces: [String]) async {
        if case .ready(let old) = loadState { old.close() }
        loadState = .loading
        do {
            loadState = .ready(try await Concierge.conversation(surfaces: surfaces))
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - App-owned UI

private struct HeadlessTranscriptView: View {
    @ObservedObject var conversation: ConciergeConversation
    var handleLink: (URL) -> Bool
    var reload: () -> Void

    @State private var draft = ""
    @Environment(\.openURL) private var openURL

    private var isResponding: Bool { conversation.state == .responding }

    var body: some View {
        VStack(spacing: 0) {
            if case .closed(let reason) = conversation.state {
                VStack(spacing: 12) {
                    Text("Conversation ended (\(String(describing: reason))).")
                    Button("Start a new conversation", action: reload)
                }
                .padding()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversation.messages.isEmpty { welcome }
                        ForEach(conversation.messages) { message in
                            row(for: message).id(message.id)
                        }
                        if isResponding, conversation.messages.last?.role != .agent || conversation.messages.last?.isStreaming == false {
                            ProgressView().padding(.vertical, 4)
                        }
                        if case .failed(let error) = conversation.state {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("We couldn't reach the assistant (\(error.localizedDescription)).",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundColor(.red)
                                Button("Retry") { conversation.retry() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.last?.text) { _ in
                    guard let id = conversation.messages.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            Divider()
            composer
        }
        .environment(\.openURL, OpenURLAction { url in
            conversation.track(.linkClicked(url: url.absoluteString))
            return handleLink(url) ? .handled : .systemAction
        })
        .onAppear { conversation.track(.opened) }
        .onDisappear { conversation.track(.closed) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Headless Concierge").font(.title2.bold())
            Text("Rendered by the app from ConciergeConversation.messages.")
                .font(.subheadline).foregroundColor(.secondary)
            ForEach([BuyNowMockURLProtocol.productCardsPrompt, "What can you help me with?"], id: \.self) { prompt in
                Button(prompt) {
                    conversation.track(.promptSuggestionClicked(prompt))
                    conversation.send(prompt)
                }
                .buttonStyle(.bordered)
                .disabled(isResponding)
            }
        }
    }

    @ViewBuilder
    private func row(for message: ConciergeMessage) -> some View {
        if message.role == .app {
            Text(message.text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(12)
            }
        } else {
            agentRow(message)
        }
    }

    private func agentRow(_ message: ConciergeMessage) -> some View {
        let products = message.elements.compactMap { element -> ConciergeProductCard? in
            if case .productCard(let card) = element { return card }
            return nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(markdown(message.text))
            if !message.isStreaming {
                ForEach(message.sources, id: \.self) { source in
                    Button("[\(source.citationNumber)] \(source.title)") {
                        conversation.track(.sourceClicked(source))
                        open(source.url)
                    }
                    .font(.caption)
                }
            }
            if !products.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(products.enumerated()), id: \.offset) { productCard($0.element) }
                    }
                }
            }
            ForEach(Array(message.elements.enumerated()), id: \.offset) { _, element in
                if case .ctaButton(let label, let url, _) = element {
                    Button(label) {
                        conversation.track(.ctaClicked(label: label, url: url))
                        if let url { open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            ForEach(message.promptSuggestions, id: \.self) { suggestion in
                Button {
                    conversation.track(.promptSuggestionClicked(suggestion))
                    conversation.send(suggestion)
                } label: {
                    Label(suggestion, systemImage: "arrow.turn.down.right").font(.footnote)
                }
                .buttonStyle(.bordered)
                .disabled(isResponding)
            }
            if message.feedbackEnabled {
                HStack(spacing: 16) {
                    thumb(.positive, symbol: "hand.thumbsup", message: message)
                    thumb(.negative, symbol: "hand.thumbsdown", message: message)
                }
                .font(.footnote)
            }
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func thumb(_ sentiment: FeedbackSentiment, symbol: String, message: ConciergeMessage) -> some View {
        Button {
            conversation.sendFeedback(messageId: message.id, ConciergeFeedback(sentiment: sentiment))
        } label: {
            Image(systemName: message.feedback == sentiment ? symbol + ".fill" : symbol)
        }
        .disabled(message.feedback != nil)
    }

    private func productCard(_ card: ConciergeProductCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: card.productImageURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color(UIColor.tertiarySystemFill)
            }
            .frame(width: 160, height: 120)
            .onTapGesture {
                conversation.track(.productCardClicked(card))
                if let url = card.productPageURL { open(url) }
            }
            if let badge = card.productBadge { Text(badge).font(.caption2.bold()).foregroundColor(.orange) }
            Text(card.productName ?? "").font(.subheadline.bold()).lineLimit(2)
            if let price = card.productPrice {
                HStack(spacing: 4) {
                    Text(price).font(.subheadline)
                    if let was = card.productWasPrice { Text(was).font(.caption).strikethrough().foregroundColor(.secondary) }
                }
            }
            ForEach([card.primary, card.secondary].compactMap { $0 }, id: \.text) { action in
                Button(action.text) {
                    conversation.track(.productActionClicked(card, action))
                    if let url = action.url { open(url) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(width: 160, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Color(UIColor.separator)))
    }

    private var composer: some View {
        HStack {
            TextField("Ask anything", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            if isResponding {
                Button { conversation.cancel() } label: { Image(systemName: "stop.circle.fill") }
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || conversation.state.isClosed)
            }
        }
        .font(.title3)
        .padding()
    }

    private func send() {
        if conversation.send(draft) == .accepted { draft = "" }
    }

    /// Taps are tracked by the caller with the specific interaction, so this only opens the URL.
    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        if !handleLink(url) { openURL(url) }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
