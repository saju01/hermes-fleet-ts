import XCTest
import FleetUI
import FleetCore

/// F2 — QR pairing apply tests: one scanned payload fills the whole
/// Add-Gateway draft (endpoint + username/password strategy + credentials),
/// through the same decode + normalization path the camera scanner uses.
@MainActor
final class F2PairingApplyTests: XCTestCase {

    private func makeStoreWithAddDraft() -> GatewayFormDraftStore {
        let store = GatewayFormDraftStore()
        store.begin(pendingSheet: .add, initial: nil)
        return store
    }

    private func v2QR(origin: String = "https://gateway.example.ts.net", auth: String = #"{"strategy":"usernamePassword","username":"fixture-user","password":"NOT-A-CREDENTIAL"}"#) -> String {
        """
        {"v":2,"kind":"hermes-fleet-ts","url":"\(origin)","name":"Fixture","transport":"embeddedTailscale","auth":\(auth)}
        """
    }

    func testV2NativePasswordScanSelectsEmbeddedTransportWithoutManualSecretFields() throws {
        let store = makeStoreWithAddDraft()
        try store.applyPairing(v2QR())
        XCTAssertEqual(store.transport, .embeddedTailscale)
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.endpointText, "https://gateway.example.ts.net")
        XCTAssertEqual(store.displayName, "Fixture")
        XCTAssertEqual(store.usernameText, "fixture-user")
        XCTAssertEqual(store.passwordText, "NOT-A-CREDENTIAL", "QR populates existing native Authentication fields")
        XCTAssertEqual(store.tokenText, "")
        XCTAssertFalse(store.confirmsTLSFirstUse)
        XCTAssertNotNil(store.pendingEnrollment)
    }

    func testV2NativeTokenAndExplicitPortsRemainSupported() throws {
        let store = makeStoreWithAddDraft()
        for origin in ["https://gateway.example.ts.net", "https://gateway.example.ts.net:443", "https://gateway.example.ts.net:9443"] {
            try store.applyPairing(v2QR(origin: origin, auth: #"{"strategy":"sessionToken","token":"NOT-A-CREDENTIAL"}"#))
            XCTAssertEqual(store.strategy, .sessionToken)
            XCTAssertEqual(store.endpointText, origin)
            XCTAssertEqual(store.transport, .embeddedTailscale)
        }
    }

    func testV2RejectsUnsafeOriginsAndMixedAuthenticationWithoutChangingDraft() throws {
        let store = makeStoreWithAddDraft()
        store.displayName = "Kept"
        for origin in ["http://gateway.example.ts.net", "https://gateway.example.invalid", "https://u:p@gateway.example.ts.net", "https://gateway.example.ts.net/path", "https://gateway.example.ts.net?x=y", "https://gateway.example.ts.net#secret", "https://gateway.example.ts.net:0", "https://gateway.example.ts.net:65536", "https://gateway..ts.net"] {
            XCTAssertThrowsError(try store.applyPairing(v2QR(origin: origin)))
            XCTAssertEqual(store.displayName, "Kept")
        }
        for auth in [#"{"strategy":"none"}"#, #"{"strategy":"sessionToken","token":""}"#, #"{"strategy":"usernamePassword","username":"u","password":""}"#, #"{"strategy":"sessionToken","token":"x","username":"u","password":"p"}"#] {
            XCTAssertThrowsError(try store.applyPairing(v2QR(auth: auth)))
        }
    }

    func testGuidanceTakesCredentialsOnceAndCancelOrLegacyScanClearsThem() throws {
        let store = makeStoreWithAddDraft()
        try store.applyPairing(v2QR())
        let enrollment = try XCTUnwrap(store.takeEnrollment())
        XCTAssertNil(store.pendingEnrollment)
        XCTAssertNil(store.takeEnrollment())
        XCTAssertEqual(store.pairingOrigin, enrollment.origin)
        store.clear()
        XCTAssertNil(store.pairingOrigin)
        try store.applyPairing(v2QR())
        try store.applyPairing(PairingPayload(url: "https://gateway.example.invalid", username: "u", password: "p").encoded())
        XCTAssertNil(store.pendingEnrollment)
        XCTAssertNil(store.pairingOrigin)
        try store.applyPairing(v2QR())
        store.begin(pendingSheet: .add, initial: nil)
        XCTAssertNil(store.pendingEnrollment)
    }

    // MARK: Happy path — one scan fills the form

    func testApplyPairingFillsEntireDraft() throws {
        let store = makeStoreWithAddDraft()
        let payload = PairingPayload(
            url: "https://gateway.example.invalid:8642",
            username: "fixture-user",
            password: "NOT-A-CREDENTIAL"
        )

        try store.applyPairing(payload.encoded())

        XCTAssertEqual(store.displayName, "gateway.example.invalid", "display name derives from the endpoint host")
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.usernameText, "fixture-user")
        XCTAssertEqual(store.passwordText, "NOT-A-CREDENTIAL")
        XCTAssertEqual(store.tokenText, "", "token field unused by the pairing strategy")
        XCTAssertFalse(store.confirmsCleartextSend)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.pendingSheet, .add, "apply keeps the draft in progress — Save is still explicit")
    }

    func testApplyPairingOverwritesPreviouslyTypedValues() throws {
        let store = makeStoreWithAddDraft()
        store.displayName = "Typed Name"
        store.endpointText = "http://typed.example.com:1"
        store.strategy = .bearerToken
        store.tokenText = "old-token"

        try store.applyPairing(PairingPayload(url: "https://gateway.example.invalid:8642", username: "u", password: "p").encoded())

        XCTAssertEqual(store.displayName, "gateway.example.invalid")
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.tokenText, "", "stale token from a previous strategy must not survive")
        XCTAssertEqual(store.usernameText, "u")
        XCTAssertEqual(store.passwordText, "p")
    }

    // MARK: Endpoint hygiene (P1-6 invariants preserved through pairing)

    func testApplyPairingRejectsUserInfoInEndpoint() {
        let store = makeStoreWithAddDraft()
        // A QR must not smuggle user:pass@host — same rule as typed input.
        let hostile = PairingPayload(url: "http://evil:pass@gateway.example.invalid:8642", username: "u", password: "p")
        XCTAssertThrowsError(try store.applyPairing(hostile.encoded()))
        XCTAssertEqual(store.endpointText, "", "a rejected scan must not partially fill the form")
        XCTAssertEqual(store.passwordText, "")
    }

    func testApplyPairingStripsQueryAndFragment() throws {
        let store = makeStoreWithAddDraft()
        let payload = PairingPayload(url: "https://gateway.example.invalid:8642/ws?token=x#frag", username: "u", password: "p")
        try store.applyPairing(payload.encoded())
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642/ws", "query/fragment stripped by normalizedOrigin")
    }

    // MARK: Decode failures leave the draft untouched

    func testApplyPairingRejectsNonPairingJSON() {
        let store = makeStoreWithAddDraft()
        store.displayName = "Kept"
        XCTAssertThrowsError(try store.applyPairing("{\"hello\":\"world\"}")) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .notAPairingPayload)
        }
        XCTAssertEqual(store.displayName, "Kept", "a bad scan never clobbers typed state")
    }

    func testApplyPairingRejectsFutureVersion() {
        let store = makeStoreWithAddDraft()
        XCTAssertThrowsError(
            try store.applyPairing("{\"password\":\"p\",\"url\":\"http://h\",\"username\":\"u\",\"v\":2}")
        ) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .unsupportedVersion(2))
        }
    }

    // MARK: Draft lifecycle still holds

    func testClearAfterPairingWipesSecrets() throws {
        let store = makeStoreWithAddDraft()
        try store.applyPairing(PairingPayload(url: "https://gateway.example.invalid:8642", username: "u", password: "secret").encoded())
        store.clear()
        XCTAssertEqual(store.usernameText, "")
        XCTAssertEqual(store.passwordText, "")
        XCTAssertFalse(store.isInProgress)
    }
}
