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
import UIKit
import Vision
import AEPServices

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Processes screen context and generates a contextual opening message using Apple's on-device Foundation Models (iOS 26+).
///
/// When a screen snapshot is provided, Vision OCR extracts visible text which is then summarized
/// by the on-device language model to produce a contextually relevant opening message.
/// The generated text is pre-populated into the compact overlay input field when it first appears,
/// giving the user a ready-to-send message they can edit or send immediately.
enum IntelligentContextEngineService {

    /// Extracts visible text from a screen snapshot using Vision OCR.
    ///
    /// - Parameter image: The screen snapshot to process.
    /// - Returns: Extracted text joined into a single string, or `nil` if extraction fails.
    private static func extractText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    /// Processes screen context and generates a suggested opening message for starting a concierge conversation.
    ///
    /// When a screen snapshot is provided, Vision OCR extracts visible text from the image,
    /// which the on-device `SystemLanguageModel` uses to produce a short, context-aware message
    /// tailored to what the user is currently viewing. Falls back to a generic brand greeting
    /// when no snapshot is provided. Returns `nil` on iOS < 26, when the model is unavailable,
    /// or if generation fails — the overlay simply shows an empty input in those cases.
    ///
    /// - Parameters:
    ///   - brandName: The brand name used to personalize the prompt.
    ///   - screenSnapshot: An optional screenshot captured before the overlay appeared.
    /// - Returns: A short context-aware message ready to be placed in the input field, or `nil`.
    static func processContext(brandName: String, screenSnapshot: UIImage? = nil) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        let context = brandName.isEmpty ? "a brand assistant" : brandName
        let prompt: String

        if let snapshot = screenSnapshot,
           let extractedText = await extractText(from: snapshot),
           !extractedText.isEmpty {
            prompt = """
            A customer is viewing a screen in the \(context) app. \
            The visible text on screen is: "\(extractedText)". \
            Write a single short summary message that can provide content to \(context)'s AI assistant \
            based on what they are looking at. Keep it natural, friendly, and under 50 words. \
            Return only the message text — no quotes, no explanation. Skip any navigation related items
            like Settings, cart, home etc.
            Assume all products are Nike Brand.
            Example: "Product details Air Dunk Elite $139 Add to cart Premium shoes for max performance."
            the result returned should be similar to: "Currently looking at Nike Air Dunk Elite shoe product detail page"

            If there are multiple products, list their names.
            Example: Nike Dunk High 159.99, Quick Dry Shorts 49.99, Team Jersey Pro 79.99 basketball
            Result expected:  Currently viewing Nike Dunk High Shoes, Nike Quick Dry Shorts, Nike Team Jersy Pro"
            """
        } else {
            prompt = """
            Write a single short opening message that a customer might send to start a conversation \
            with \(context)'s AI assistant. Keep it friendly, open-ended, and under 50 words. \
            Return only the message text — no quotes, no explanation.
            """
        }
        Log.trace(label: "Intelligence Service", "Sending prompt: \(prompt)")

        let session = LanguageModelSession()
        let response = try? await session.respond(to: prompt)
        return response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }

    /// Generates a concise shopping intent summary from the user's recent in-app actions.
    ///
    /// This is a separate LLM call from `processContext` and is shown as an additional
    /// intelligence bubble in the compact overlay. Its result is never sent to the chat service —
    /// it exists solely to surface a real-time behavioural insight to the user.
    ///
    /// - Parameters:
    ///   - recentActions: A comma-separated string of the user's last N actions, e.g.
    ///     "viewed Nike Air Max, added Nike Dunk High to cart, removed Nike Shorts from cart".
    ///   - brandName: The brand name used to personalise the insight.
    /// - Returns: A short intent insight string, or `nil` if generation is unavailable or fails.
    static func processActionLog(recentActions: String, brandName: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        guard !recentActions.isEmpty else { return nil }

        let context = brandName.isEmpty ? "a brand" : brandName
        let prompt = """
        A customer using the \(context) app has recently: \(recentActions).
        Write a single short summary about their shopping actions. \
        Keep it under 25 words. Return only the insight text — no quotes, no explanation.
        Example input: "viewed Nike Air Max, added Nike Dunk High to cart"
        Example output: "Browsed Air Max, Nike Dunk High in cart"
        
        Example input: "viewed Nike Zoom Fly, Nike Pegasus 41 "
        Example output: "Browsed Pegasus and Zoom Fly. Cart empty"
        """
        Log.trace(label: "Intelligence Service", "Sending action log prompt: \(prompt)")

        let session = LanguageModelSession()
        let response = try? await session.respond(to: prompt)
        return response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }
}
