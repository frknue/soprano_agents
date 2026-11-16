import CryptoKit
import Foundation

/// A phone or browser that redeemed the pairing code.
struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    /// SHA-256 (hex) of the device token; the token itself is never stored.
    var tokenHash: String
    var pairedAt: Date
    var lastSeenAt: Date?
}

/// The paired devices' token hashes, readable off the main actor: the server checks a request's
/// token from its head before reading the body.
final class TokenIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes: [String] = []

    func update(_ hashes: [String]) {
        lock.withLock { self.hashes = hashes }
    }

    func contains(token: String) -> Bool {
        let hash = RemoteStore.hash(token)
        let hashes = lock.withLock { self.hashes }
        return hashes.reduce(false) { $0 || RemoteStore.constantTimeEqual($1, hash) }
    }
}

/// Remote access state in `<app data>/remote.json`: the pairing code, paired devices, the VAPID
/// keys and push subscriptions. Main-actor only (except `tokens`); every change is written at
/// once (owner-only file permissions).
@MainActor
final class RemoteStore {
    private struct Contents: Codable {
        var pairingCode: String
        var devices: [PairedDevice] = []
        var vapid: VAPIDKeys
        var subscriptions: [PushSubscription] = []
    }

    let url: URL
    nonisolated let tokens = TokenIndex()
    private var contents: Contents
    private let now: () -> Date
    private let observers = ObserverList<Void>()

    init(url: URL, now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let data = try? Data(contentsOf: url), let contents = try? RemoteJSON.decoder.decode(Contents.self, from: data) {
            self.contents = contents
            tokens.update(contents.devices.map(\.tokenHash))
        } else {
            contents = Contents(pairingCode: Self.randomToken(), vapid: .generate())
            save()
        }
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.add(owner) { _ in handler() }
    }

    // MARK: Pairing

    var pairingCode: String { contents.pairingCode }
    var devices: [PairedDevice] { contents.devices }

    /// Invalidates the current pairing link (paired devices stay).
    func rotatePairingCode() {
        contents.pairingCode = Self.randomToken()
        save()
    }

    /// Redeems the pairing code for a new device token; nil when the code is wrong. A code works
    /// once: pairing replaces it, so a link seen or copied earlier can't pair another device.
    func pair(code: String, name: String) -> String? {
        guard Self.constantTimeEqual(code, contents.pairingCode) else { return nil }
        contents.pairingCode = Self.randomToken()
        let token = Self.randomToken()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        contents.devices.append(PairedDevice(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? "Device" : String(trimmed.prefix(60)),
            tokenHash: Self.hash(token),
            pairedAt: now()
        ))
        save()
        return token
    }

    /// The device a token belongs to; records when it was last seen (at most once a minute).
    func device(forToken token: String) -> PairedDevice? {
        let hash = Self.hash(token)
        guard let index = contents.devices.firstIndex(where: { Self.constantTimeEqual($0.tokenHash, hash) }) else { return nil }
        let date = now()
        if (contents.devices[index].lastSeenAt ?? .distantPast).addingTimeInterval(60) < date {
            contents.devices[index].lastSeenAt = date
            save()
        }
        return contents.devices[index]
    }

    /// Forgets the device and its push subscriptions.
    func revoke(deviceID: String) {
        contents.devices.removeAll { $0.id == deviceID }
        contents.subscriptions.removeAll { $0.deviceID == deviceID }
        save()
    }

    // MARK: Push

    var vapidKeys: VAPIDKeys { contents.vapid }

    /// Subscriptions of devices that are still paired.
    var subscriptions: [PushSubscription] {
        let devices = Set(contents.devices.map(\.id))
        return contents.subscriptions.filter { $0.deviceID.map(devices.contains) ?? false }
    }

    func addSubscription(_ subscription: PushSubscription) {
        contents.subscriptions.removeAll { $0.endpoint == subscription.endpoint }
        contents.subscriptions.append(subscription)
        save()
    }

    func removeSubscription(endpoint: String) {
        let count = contents.subscriptions.count
        contents.subscriptions.removeAll { $0.endpoint == endpoint }
        if contents.subscriptions.count != count { save() }
    }

    // MARK: Helpers

    /// Writes a temporary file created owner-only, then renames it over `remote.json`: the VAPID
    /// private key and token hashes are never readable by others, not even mid-write.
    private func save() {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try RemoteJSON.encoder.encode(contents)
            let temporary = directory.appendingPathComponent(".remote-\(UUID().uuidString).json")
            // `open` with mode 0600 creates it owner-only; nothing is written before that.
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            NSLog("Soprano Agents: could not save %@: %@", url.path, error.localizedDescription)
        }
        tokens.update(contents.devices.map(\.tokenHash))
        observers.notify(())
    }

    /// 32 random bytes, base64url.
    nonisolated static func randomToken() -> String {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }).base64URLEncodedString()
    }

    nonisolated static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
