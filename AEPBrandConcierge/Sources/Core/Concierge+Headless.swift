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

/// Public API for apps that render their own chat UI.
public extension Concierge {

    /// Opens a conversation for `surfaces`, for apps that render their own chat UI.
    ///
    /// Resolves configuration the same way `show(surfaces:)` does, so the Concierge extension,
    /// Edge and Edge Identity must be registered. One conversation is live per surface set: this one
    /// replaces the previous conversation on the same surfaces, headless or the SDK chat UI's, which
    /// closes with `.replaced`. Conversations on other surfaces stay live; all share one backend
    /// session, and a data handoff goes to the one most recently opened or used. It resumes the
    /// persisted backend session if it is still active, or starts a new one, and keeps that session
    /// for its whole life. It runs turns, keeps the transcript in `messages`, reports turn
    /// analytics, and can receive `Concierge.sendDataHandoff(...)`. Call `close()` when done;
    /// replacement, session expiry and identity reset also close it.
    ///
    /// - Throws: `ConciergeError.configurationUnavailable` if configuration can't be resolved (ex:
    ///   Edge Identity not yet ready, or an identity reset happened while resolving).
    @MainActor
    static func conversation(surfaces: [String]) async throws -> ConciergeConversation {
        let (config, generation) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(ConciergeConfiguration, Int), Error>) in
            fetchChatConfiguration(forSurfaces: surfaces,
                                   onFailure: { continuation.resume(throwing: ConciergeError.configurationUnavailable) },
                                   completion: { config, generation in continuation.resume(returning: (config, generation)) })
        }
        guard ConciergeIdentityBoundary.shared.admits(generation) else { throw ConciergeError.configurationUnavailable }
        // Pins the session exactly as presenting the chat UI does: resumes it if active, else starts one.
        let core = ConciergeConversationCore(configuration: config,
                                             urlSessionConfiguration: resolvedURLSessionConfiguration(),
                                             buffersSSEFrames: true,
                                             identityGeneration: generation)
        let conversation = ConciergeConversation(core: core, dispatch: { MobileCore.dispatch(event: $0) })
        ConciergeActiveConversation.activate(conversation)
        conversation.report(.sessionInitialized)
        return conversation
    }
}
