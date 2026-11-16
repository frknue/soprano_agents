import CryptoKit
import Foundation

/// The app's VAPID identity: the P-256 key that signs push requests (RFC 8292).
struct VAPIDKeys: Codable, Sendable {
    let signingKey: P256.Signing.PrivateKey

    init(signingKey: P256.Signing.PrivateKey) {
        self.signingKey = signingKey
    }

    static func generate() -> VAPIDKeys {
        VAPIDKeys(signingKey: P256.Signing.PrivateKey())
    }

    /// The application server key browsers subscribe with: base64url of the uncompressed point.
    var publicKey: String {
        signingKey.publicKey.x963Representation.base64URLEncodedString()
    }

    private enum CodingKeys: String, CodingKey {
        case privateKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .privateKey)
        guard let raw = Data(base64URLEncoded: encoded) else {
            throw DecodingError.dataCorruptedError(forKey: .privateKey, in: container, debugDescription: "Not base64url")
        }
        signingKey = try P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signingKey.rawRepresentation.base64URLEncodedString(), forKey: .privateKey)
    }
}

/// One device's push subscription as the browser's `PushManager` reports it.
struct PushSubscription: Codable, Sendable, Hashable {
    var endpoint: String
    /// The user agent's P-256 public key, base64url.
    var p256dh: String
    /// The user agent's authentication secret, base64url.
    var auth: String
    var createdAt: Date
    /// The paired device that subscribed (`PairedDevice.id`); revoking it drops the subscription.
    var deviceID: String?
}

enum WebPushError: Error, Equatable {
    case payloadTooLarge(Int)
    case invalidEndpoint
}

/// Message encryption for Web Push (RFC 8291, `aes128gcm` content coding of RFC 8188).
enum WebPushCrypto {
    /// The largest plaintext that fits one 4096-byte record.
    static let maximumPayload = 3993
    static let recordSize: UInt32 = 4096

    /// Encrypts `payload` for the subscription keys and returns the full request body (header and one record).
    static func encrypt(
        _ payload: Data,
        p256dh: Data,
        auth: Data,
        salt: Data = WebPushCrypto.randomSalt(),
        localKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
    ) throws -> Data {
        guard payload.count <= maximumPayload else { throw WebPushError.payloadTooLarge(payload.count) }
        let userAgentKey = try P256.KeyAgreement.PublicKey(x963Representation: p256dh)
        let userAgentPublic = userAgentKey.x963Representation
        let serverPublic = localKey.publicKey.x963Representation
        let secret = try localKey.sharedSecretFromKeyAgreement(with: userAgentKey)

        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(userAgentPublic)
        keyInfo.append(serverPublic)
        let inputKeyMaterial = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: keyInfo, outputByteCount: 32)

        let contentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16
        )
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12
        )

        var plaintext = payload
        plaintext.append(0x02)
        let sealed = try AES.GCM.seal(plaintext, using: contentKey, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))

        var body = salt
        withUnsafeBytes(of: recordSize.bigEndian) { body.append(contentsOf: $0) }
        body.append(UInt8(serverPublic.count))
        body.append(serverPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
}

/// VAPID request authorization (RFC 8292).
enum VAPID {
    private struct Claims: Encodable {
        let aud: String
        let exp: Int
        let sub: String
    }

    /// The `Authorization` header value for a push to `endpoint`, valid for 12 hours from `now`.
    static func authorization(endpoint: URL, subject: String, keys: VAPIDKeys, now: Date) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw WebPushError.invalidEndpoint }
        let audience = endpoint.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        let claims = Claims(aud: audience, exp: Int(now.timeIntervalSince1970) + 12 * 60 * 60, sub: subject)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let header = Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8).base64URLEncodedString()
        let payload = try encoder.encode(claims).base64URLEncodedString()
        let signingInput = "\(header).\(payload)"
        let signature = try keys.signingKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "vapid t=\(signingInput).\(signature.base64URLEncodedString()), k=\(keys.publicKey)"
    }
}

/// Delivers encrypted push messages to subscription endpoints.
struct WebPushSender: Sendable {
    enum Outcome: Sendable, Equatable {
        case delivered
        /// The subscription no longer exists; drop it.
        case gone
        case failed(String)
    }

    let keys: VAPIDKeys
    let subject: String
    let session: URLSession

    init(keys: VAPIDKeys, subject: String = "mailto:soprano-agents@localhost", session: URLSession = .shared) {
        self.keys = keys
        self.subject = subject
        self.session = session
    }

    func send(_ payload: Data, to subscription: PushSubscription, ttl: Int = 86400, urgency: String = "high") async -> Outcome {
        guard let endpoint = URL(string: subscription.endpoint) else { return .failed("invalid endpoint") }
        guard let p256dh = Data(base64URLEncoded: subscription.p256dh), let auth = Data(base64URLEncoded: subscription.auth) else {
            return .failed("invalid subscription keys")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        do {
            request.httpBody = try WebPushCrypto.encrypt(payload, p256dh: p256dh, auth: auth)
            request.setValue(try VAPID.authorization(endpoint: endpoint, subject: subject, keys: keys, now: Date()), forHTTPHeaderField: "Authorization")
        } catch {
            return .failed("\(error)")
        }
        request.setValue(String(ttl), forHTTPHeaderField: "TTL")
        request.setValue(urgency, forHTTPHeaderField: "Urgency")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("no HTTP response") }
            switch http.statusCode {
            case 200..<300: return .delivered
            case 404, 410: return .gone
            default:
                let body = String(decoding: data.prefix(200), as: UTF8.self)
                return .failed("\(http.statusCode) \(body)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url, with or without padding.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
