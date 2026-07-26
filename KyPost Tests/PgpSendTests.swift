//
//  PgpSendTests.swift
//  KyPost Tests
//
//  Encrypted send from a paired client (Client_Encrypted_Send.md): the key
//  custody rule, the two /api/pgp preflight calls, and compose's keyless
//  confirmation and webmail handoff. Relay send/draft wire tests live in
//  MailTests.swift with the other relay tests.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Key custody

@Suite struct PgpKeyCustodyTests {
    @Test func serverProtectionIsTheOnlyNativeSendMode() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: "server") == .serverHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: "client") == .clientHeld)
    }

    @Test func noIdentityMeansPlaintextOnly() {
        #expect(pgpKeyCustody(hasIdentity: false, protection: "server") == .noIdentity)
        #expect(pgpKeyCustody(hasIdentity: nil, protection: nil) == .noIdentity)
        // An identity-less account reports protection "" (the spec's table).
        #expect(pgpKeyCustody(hasIdentity: true, protection: "") == .noIdentity)
    }

    /// Degrade, never guess: an unknown mode must not promise an encrypted
    /// send this app cannot deliver.
    @Test func unknownProtectionDegradesToClientHeld() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: "hsm") == .clientHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: nil) == .clientHeld)
    }

    @Test func protectionIsReadTolerantly() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: " Server ") == .serverHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: "SERVER") == .serverHeld)
    }
}
