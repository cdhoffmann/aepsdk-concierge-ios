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

/// Headless (thin core + turn assembler) POC: a chat UI the *app* owns, built only on the public
/// `ConciergeConversationCore.sendTurn` + `Concierge.track`. The SDK assembles each response and
/// reports turn analytics; the app owns the transcript, rendering and tap tracking.
struct HeadlessCoreChatView: View {
    let surfaces: [String]
    @Binding var useMockResponses: Bool
    var handleLink: (URL) -> Bool

    @StateObject private var model = HeadlessCoreChatModel()

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Use Buy Now mock responses", isOn: $useMockResponses)
                .font(.footnote)
                .padding(.horizontal)
            Divider()
            switch model.loadState {
            case .loading:
                ProgressView().frame(maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Retry") { Task { await model.load(surfaces: surfaces) } }
                }
                .padding()
                .frame(maxHeight: .infinity)
            case .ready:
                HeadlessCoreTranscriptView(model: model, handleLink: handleLink)
            }
        }
        .task { await model.load(surfaces: surfaces) }
    }
}

// MARK: - App-owned state (what the customer writes)

struct HeadlessCoreMessage: Identifiable {
    enum Role { case user, agent }

    let id = UUID()
    let role: Role
    var userText = ""
    var turn = ConciergeTurn()
    var feedbackSentiment: FeedbackSentiment?
    var failed = false

    var text: String { role == .user ? userText : turn.text }
    var products: [MultimodalElement] { turn.products }
    var ctas: [ActionButton] { turn.ctaButtons }
    var suggestions: [String] { turn.isComplete ? turn.promptSuggestions : [] }
    var sources: [Source] { turn.isComplete ? turn.sources : [] }
    var isComplete: Bool { failed || turn.isComplete }
    var feedbackEligible: Bool { turn.feedbackEligible }
}

@MainActor
final class HeadlessCoreChatModel: ObservableObject {
    enum LoadState { case loading, ready, failed(String) }

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var messages: [HeadlessCoreMessage] = []
    @Published private(set) var isProcessing = false

    private var core: ConciergeConversationCore?
    private var turnTask: Task<Void, Never>?
    private var openedAt: Date?

    func load(surfaces: [String]) async {
        loadState = .loading
        do {
            core = try await Concierge.conversationCore(surfaces: surfaces)
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func opened() {
        openedAt = Date()
        Concierge.track(.chatOpened)
    }

    func closed() {
        let millis = openedAt.map { Int64(Date().timeIntervalSince($0) * 1000) } ?? 0
        Concierge.track(.chatClosed(durationMillis: millis))
    }

    func send(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let core, !query.isEmpty, !isProcessing else { return }
        if core.isEnded {
            loadState = .failed("Conversation ended after an identity reset.")
            return
        }

        messages.append(HeadlessCoreMessage(role: .user, userText: query))
        messages.append(HeadlessCoreMessage(role: .agent))
        let index = messages.count - 1
        isProcessing = true

        // querySubmitted, responseStarted/Completed, cardsRendered and errorOccurred are reported by sendTurn.
        turnTask = Task {
            do {
                for try await turn in core.sendTurn(query) {
                    messages[index].turn = turn
                }
            } catch {
                messages[index].failed = true
            }
            isProcessing = false
        }
    }

    func cancel() {
        turnTask?.cancel()
    }

    func sendFeedback(for id: UUID, sentiment: FeedbackSentiment) {
        guard let core, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].feedbackSentiment = sentiment
        core.sendFeedback(conversationId: messages[index].turn.conversationId,
                          interactionId: messages[index].turn.interactionId,
                          sentiment: sentiment)
    }
}

// MARK: - App-owned UI

private struct HeadlessCoreTranscriptView: View {
    @ObservedObject var model: HeadlessCoreChatModel
    var handleLink: (URL) -> Bool

    @State private var draft = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.messages.isEmpty { welcome }
                        ForEach(model.messages) { message in
                            row(for: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.last?.text) { _ in
                    guard let id = model.messages.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            Divider()
            composer
        }
        .environment(\.openURL, OpenURLAction { url in
            Concierge.track(.linkClicked(url: url.absoluteString))
            return handleLink(url) ? .handled : .systemAction
        })
        .onAppear { model.opened() }
        .onDisappear { model.closed() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Headless Concierge (core + turns)").font(.title2.bold())
            Text("Rendered by the app from assembled ConciergeTurn values.")
                .font(.subheadline).foregroundColor(.secondary)
            ForEach([BuyNowMockURLProtocol.productCardsPrompt, "What can you help me with?"], id: \.self) { prompt in
                Button(prompt) {
                    Concierge.track(.promptSuggestionClicked(prompt))
                    model.send(prompt)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func row(for message: HeadlessCoreMessage) -> some View {
        if message.role == .user {
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

    private func agentRow(_ message: HeadlessCoreMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.failed {
                Label("We couldn't reach the assistant. Try again.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
            } else if message.text.isEmpty && !message.isComplete {
                ProgressView().padding(.vertical, 4)
            } else {
                Text(markdown(message.text))
            }
            if !message.sources.isEmpty {
                ForEach(message.sources, id: \.self) { source in
                    Button("[\(source.citationNumber)] \(source.title)") { open(source.url) }
                        .font(.caption)
                }
            }
            if !message.products.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(message.products.enumerated()), id: \.offset) { productCard($0.element) }
                    }
                }
            }
            ForEach(message.ctas, id: \.text) { cta in
                Button(cta.text) { tapCTA(cta) }.buttonStyle(.borderedProminent)
            }
            ForEach(message.suggestions, id: \.self) { suggestion in
                Button {
                    Concierge.track(.promptSuggestionClicked(suggestion))
                    model.send(suggestion)
                } label: {
                    Label(suggestion, systemImage: "arrow.turn.down.right").font(.footnote)
                }
                .buttonStyle(.bordered)
                .disabled(model.isProcessing)
            }
            if message.feedbackEligible {
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

    private func thumb(_ sentiment: FeedbackSentiment, symbol: String, message: HeadlessCoreMessage) -> some View {
        Button {
            model.sendFeedback(for: message.id, sentiment: sentiment)
        } label: {
            Image(systemName: message.feedbackSentiment == sentiment ? symbol + ".fill" : symbol)
        }
        .disabled(message.feedbackSentiment != nil)
    }

    private func productCard(_ element: MultimodalElement) -> some View {
        let info = element.entityInfo
        return VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: info?.productImageURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color(UIColor.tertiarySystemFill)
            }
            .frame(width: 160, height: 120)
            .onTapGesture {
                Concierge.track(.productClicked(element))
                if let url = info?.productPageURL { open(url, tracked: true) }
            }
            if let badge = info?.productBadge { Text(badge).font(.caption2.bold()).foregroundColor(.orange) }
            Text(info?.productName ?? "").font(.subheadline.bold()).lineLimit(2)
            if let price = info?.productPrice {
                HStack(spacing: 4) {
                    Text(price).font(.subheadline)
                    if let was = info?.productWasPrice { Text(was).font(.caption).strikethrough().foregroundColor(.secondary) }
                }
            }
            ForEach([info?.primary, info?.secondary].compactMap { $0 }, id: \.text) { cta in
                Button(cta.text) { tapCTA(cta) }
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
            if model.isProcessing {
                Button { model.cancel() } label: { Image(systemName: "stop.circle.fill") }
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.title3)
        .padding()
    }

    private func send() {
        model.send(draft)
        draft = ""
    }

    private func tapCTA(_ cta: ActionButton) {
        guard let url = cta.url else { return }
        Concierge.track(.ctaButtonClicked(label: cta.text, url: url))
        open(url, tracked: true)
    }

    /// `tracked` skips the generic link event when a more specific one already reported it.
    private func open(_ string: String, tracked: Bool = false) {
        guard let url = URL(string: string) else { return }
        if !tracked { Concierge.track(.linkClicked(url: string)) }
        if !handleLink(url) { openURL(url) }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
