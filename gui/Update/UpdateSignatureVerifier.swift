import Foundation
import CryptoKit

public enum SignatureVerificationError: Error, Equatable, Sendable {
    case invalidPublicKey(String)
    case invalidSignatureFormat
    case signatureMismatch
    case fileReadFailed(String)
}

public protocol UpdateSignatureVerifying: Sendable {
    func verify(dmgURL: URL, signatureData: Data) throws -> Bool
}

public struct CryptoKitUpdateSignatureVerifier: UpdateSignatureVerifying {
    /// Official release signing public key (Ed25519, 32 bytes raw representation in base64).
    /// Releases are signed offline with the corresponding private key.
    public static let defaultPublicKeyBase64 = "MlcCyStTTvXrlLZ/lBceSKWUZ6JGfqHZUXCbzADQHlA="

    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    public init(rawPublicKey: Data) throws {
        do {
            self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        } catch {
            throw SignatureVerificationError.invalidPublicKey("Failed to initialize Ed25519 public key: \(error)")
        }
    }

    public init(base64PublicKey: String = defaultPublicKeyBase64) throws {
        guard let data = Data(base64Encoded: base64PublicKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SignatureVerificationError.invalidPublicKey("Invalid base64 public key")
        }
        try self.init(rawPublicKey: data)
    }

    /// Verifies the digital signature of the given DMG file before any attach or execution occurs.
    /// Supports raw 64-byte Ed25519 signatures or ASCII base64 encoded signatures.
    public func verify(dmgURL: URL, signatureData: Data) throws -> Bool {
        let rawSignature: Data
        if signatureData.count == 64 {
            rawSignature = signatureData
        } else if let base64Str = String(data: signatureData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let decoded = Data(base64Encoded: base64Str), decoded.count == 64 {
            rawSignature = decoded
        } else {
            throw SignatureVerificationError.invalidSignatureFormat
        }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: dmgURL, options: .mappedIfSafe)
        } catch {
            throw SignatureVerificationError.fileReadFailed(error.localizedDescription)
        }

        guard publicKey.isValidSignature(rawSignature, for: fileData) else {
            throw SignatureVerificationError.signatureMismatch
        }
        return true
    }
}
