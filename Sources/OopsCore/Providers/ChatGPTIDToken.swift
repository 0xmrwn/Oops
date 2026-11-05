import Foundation
import Security

// ID-token validation as OpenAI's sign-in page asks (signature against the published JWKS; issuer,
// audience, expiry and nonce; the validated `sub` as the identity), with the rules of OpenID Connect
// Core §3.1.3.7 and the small clock tolerance of the verification example in OpenAI's website guide.
extension ChatGPTAuth {
    static let clockTolerance: TimeInterval = 5

    /// The `kid` a token's header names, to pick its key from the JWKS.
    static func keyID(_ token: String) -> String? {
        guard let head = token.split(separator: ".", omittingEmptySubsequences: false).first,
              let data = base64URLDecode(head), let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return header["kid"] as? String
    }

    /// Verifies an RS256 ID token and returns its subject and profile. `nonce` is the attempt's own on a
    /// sign-in, nil on refresh (OIDC Core §12.2: a refreshed ID token carries no new nonce).
    static func verifyIDToken(_ token: String, key: SecKey, clientID: String, nonce: String?, now: Date) throws -> (String, ChatGPTIdentity) {
        let invalid = ChatGPTError.named("invalid_id_token")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headData = base64URLDecode(parts[0]), let bodyData = base64URLDecode(parts[1]),
              let signature = base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { throw invalid }
        // The algorithm is fixed here, never taken from the token (RFC 8725 §3.1).
        guard header["alg"] as? String == "RS256" else { throw invalid }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else { throw invalid }

        let audience: [String] = (claims["aud"] as? String).map { [$0] } ?? claims["aud"] as? [String] ?? []
        let azp = claims["azp"] as? String
        guard claims["iss"] as? String == issuer, audience.contains(clientID),
              azp == nil || azp == clientID, audience.count == 1 || azp == clientID else { throw invalid }
        let time = now.timeIntervalSince1970
        guard let expires = (claims["exp"] as? NSNumber)?.doubleValue, expires + clockTolerance > time,
              let issued = (claims["iat"] as? NSNumber)?.doubleValue, issued - clockTolerance <= time else { throw invalid }
        if let notBefore = (claims["nbf"] as? NSNumber)?.doubleValue, notBefore - clockTolerance > time { throw invalid }
        if let nonce, claims["nonce"] as? String != nonce { throw invalid }
        guard let subject = claims["sub"] as? String, !subject.isEmpty else { throw invalid }
        if claims["sid"] != nil, (claims["sid"] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { throw invalid }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let identity = ChatGPTIdentity(email: claims["email"] as? String, name: claims["name"] as? String,
                                       plan: auth?["chatgpt_plan_type"] as? String)
        return (subject, identity)
    }

    /// The RSA signing keys of a JWKS document (RFC 7517), by `kid`.
    static func jwks(_ object: [String: Any]) -> [String: SecKey] {
        var keys: [String: SecKey] = [:]
        for case let jwk as [String: Any] in object["keys"] as? [Any] ?? [] {
            guard jwk["kty"] as? String == "RSA", (jwk["use"] as? String ?? "sig") == "sig", (jwk["alg"] as? String ?? "RS256") == "RS256",
                  let kid = jwk["kid"] as? String, let n = (jwk["n"] as? String).flatMap({ base64URLDecode(Substring($0)) }),
                  let e = (jwk["e"] as? String).flatMap({ base64URLDecode(Substring($0)) }), let key = rsaPublicKey(modulus: n, exponent: e) else { continue }
            keys[kid] = key
        }
        return keys
    }

    /// Security wants a PKCS #1 RSAPublicKey (RFC 8017 §A.1.1): SEQUENCE { INTEGER n, INTEGER e }, DER.
    private static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            var bytes: [UInt8] = [], rest = count
            while rest > 0 { bytes.insert(UInt8(rest & 0xff), at: 0); rest >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ data: Data) -> [UInt8] {
            var bytes = Array(data.drop(while: { $0 == 0 }))
            if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}
