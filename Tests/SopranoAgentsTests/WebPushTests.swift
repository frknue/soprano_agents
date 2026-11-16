import AppKit
import CryptoKit
import Testing
@testable import SopranoAgents

struct WebPushTests {
    private func decode(_ string: String) throws -> Data {
        try #require(Data(base64URLEncoded: string))
    }

    @Test func encryptionReproducesTheRFC8291TestVector() throws {
        let serverKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        #expect(serverKey.publicKey.x963Representation.base64URLEncodedString() == "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")

        let body = try WebPushCrypto.encrypt(
            Data("When I grow up, I want to be a watermelon".utf8),
            p256dh: decode("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
            auth: decode("BTBZMqHH6r4Tts7J_aSIgg"),
            salt: decode("DGv6ra1nlYgDCS1FRnbzlw"),
            localKey: serverKey
        )

        #expect(body.base64URLEncodedString() == "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
    }

    @Test func encryptionRejectsPayloadsLargerThanOneRecord() throws {
        let userAgent = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        #expect(throws: WebPushError.payloadTooLarge(3994)) {
            try WebPushCrypto.encrypt(Data(count: 3994), p256dh: userAgent, auth: Data(count: 16))
        }
    }

    @Test func vapidAuthorizationCarriesAVerifiableTokenForTheEndpointOrigin() throws {
        let keys = VAPIDKeys.generate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = try VAPID.authorization(
            endpoint: #require(URL(string: "https://push.example.net:8443/send/abc?x=1")),
            subject: "mailto:soprano-agents@localhost",
            keys: keys,
            now: now
        )

        let parts = header.components(separatedBy: ", ")
        #expect(parts.count == 2)
        #expect(parts[1] == "k=\(keys.publicKey)")
        let token = try #require(parts[0].split(separator: "=", maxSplits: 1).last.map(String.init))
        #expect(parts[0].hasPrefix("vapid t="))
        let segments = token.split(separator: ".").map(String.init)
        #expect(segments.count == 3)

        let publicKey = try P256.Signing.PublicKey(x963Representation: decode(keys.publicKey))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(segments[2]))
        #expect(publicKey.isValidSignature(signature, for: Data("\(segments[0]).\(segments[1])".utf8)))

        let jwtHeader = try JSONSerialization.jsonObject(with: decode(segments[0])) as? [String: String]
        #expect(jwtHeader == ["typ": "JWT", "alg": "ES256"])
        let claims = try #require(JSONSerialization.jsonObject(with: decode(segments[1])) as? [String: Any])
        #expect(claims["aud"] as? String == "https://push.example.net:8443")
        #expect(claims["exp"] as? Int == 1_700_000_000 + 12 * 60 * 60)
        #expect(claims["sub"] as? String == "mailto:soprano-agents@localhost")
    }

    @Test func base64URLRoundTripsWithoutPadding() throws {
        for length in 0..<8 {
            let data = Data((0..<length).map { UInt8(250 - $0) })
            let encoded = data.base64URLEncodedString()
            #expect(!encoded.contains("="))
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(Data(base64URLEncoded: encoded) == data)
        }
        #expect(Data(base64URLEncoded: "_-8") == Data([0xFF, 0xEF]))
    }

    @Test func vapidKeysSurviveACodableRoundTrip() throws {
        let keys = VAPIDKeys.generate()
        let decoded = try JSONDecoder().decode(VAPIDKeys.self, from: JSONEncoder().encode(keys))

        #expect(decoded.publicKey == keys.publicKey)
        #expect(try decode(keys.publicKey).count == 65)
        #expect(try decode(keys.publicKey).first == 0x04)
    }
}
