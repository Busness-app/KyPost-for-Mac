//
//  MfaApprovalViewModel.swift
//  KyPost
//
//  In-app MFA approval (spec §5) — the only place a sign-in can be approved,
//  because approving requires picking the number the browser is showing.
//

import Foundation
import Observation

@Observable
@MainActor
final class MfaApprovalViewModel {
    enum State: Equatable {
        case pending
        case sending
        case done(String)
        case failed(String)
    }

    let challengeId: String
    /// The options to offer, or nil when the server sent no usable number and
    /// the screen must fall back to a plain Approve button.
    let matchOptions: [String]?

    private let correctDigits: String
    private let approveMfaChallenge: ApproveMfaChallengeUseCase

    private(set) var state: State = .pending

    convenience init(challenge: MfaChallenge, approveMfaChallenge: ApproveMfaChallengeUseCase) {
        self.init(
            challengeId: challenge.challengeId,
            matchDigits: challenge.matchDigits,
            decoyDigits: challenge.decoyDigits,
            approveMfaChallenge: approveMfaChallenge
        )
    }

    init(
        challengeId: String,
        matchDigits: String = "",
        decoyDigits: [String] = [],
        approveMfaChallenge: ApproveMfaChallengeUseCase
    ) {
        self.challengeId = challengeId
        self.correctDigits = matchDigits
        // Shuffled exactly once, here, and held in a `let`: re-deriving it on
        // a redraw would reorder the tiles under the user's finger.
        self.matchOptions = MfaNumberMatch.options(
            correct: matchDigits,
            serverDecoys: decoyDigits
        )
        self.approveMfaChallenge = approveMfaChallenge
    }

    /// A wrong number is treated as a denial, not a retry.
    ///
    /// Letting the user guess again turns a three-way match into a one-in-three
    /// chance for an attacker whose victim is tapping blind. The comparison
    /// here only decides which request to send — the backend checks the number
    /// again on the approve path, and is the side that actually enforces it.
    func choose(_ chosen: String) async {
        if chosen == correctDigits {
            await respond(approved: true, matchDigits: chosen)
        } else {
            await respond(approved: false)
            // Overwrite the generic "denied" text: the user needs to know the
            // sign-in was refused *because the number was wrong*.
            if case .done = state {
                state = .done("That is not the number shown in the browser — the sign-in was denied.")
            }
        }
    }

    /// Defence in depth behind the UI: an approval with no number is one the
    /// server refuses anyway, and offering to send it is how a payload missing
    /// `matchDigits` used to downgrade this screen to a one-tap approve.
    func respond(approved: Bool, matchDigits: String = "") async {
        guard !approved || !matchDigits.isEmpty else {
            state = .failed(
                "This request didn't include a verification number, so it can't be approved from this device."
            )
            return
        }
        state = .sending
        let outcome = await approveMfaChallenge(
            challengeId: challengeId,
            approved: approved,
            matchDigits: matchDigits
        )
        switch outcome {
        case .success:
            state = .done(approved ? "Sign-in approved" : "Sign-in denied")
        case .rejected:
            state = .failed("The server rejected this response — the challenge may have expired.")
        case .failure(let message):
            state = .failed("\(message) — try again.")
        }
    }
}
