//
//  ApiSession.swift
//  solixmenu
//
//  Swift port of anker-solix-api/api/session.py (core session + auth + request)
//

import CommonCrypto
import CryptoKit
import Foundation

// MARK: - ApiSession Errors

enum ApiSessionError: Error, CustomStringConvertible {
    case missingApiBase
    case invalidUrl(String)
    case invalidResponse
    case invalidJson
    case encryptionFailed
    case authenticationFailed
    case missingLoginData
    case httpStatus(Int, String)

    var description: String {
        switch self {
        case .missingApiBase:
            return "API base URL is missing."
        case .invalidUrl(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid response."
        case .invalidJson:
            return "Invalid JSON response."
        case .encryptionFailed:
            return "Failed to encrypt payload."
        case .authenticationFailed:
            return "Authentication failed."
        case .missingLoginData:
            return "Login response missing required data."
        case .httpStatus(let code, let body):
            return "HTTP status \(code): \(body)"
        }
    }
}

// MARK: - ApiSession Configuration

struct ApiSessionConfiguration {
    var requestDelay: TimeInterval = SolixDefaults.requestDelayDef
    var requestTimeout: TimeInterval = TimeInterval(SolixDefaults.requestTimeoutDef)
    var endpointLimit: Int = SolixDefaults.endpointLimitDef
    var maskCredentials: Bool = true
    var logger: ((String) -> Void)? = nil
}

// MARK: - ApiSession

final class ApiSession {
    // Public
    let email: String
    private(set) var countryId: String
    private(set) var nickname: String = ""
    private(set) var apiBase: String
    private(set) var gtoken: String?
    private(set) var token: String?

    // Config
    private var config: ApiSessionConfiguration

    // Request/Session
    private let urlSession: URLSession
    private var lastRequestTime: Date?
    let requestCount = RequestCounter()
    private var retryAttempt: Int? = nil

    // Auth cache
    private var loginResponse: [String: Any] = [:]
    var loginResponseSnapshot: [String: Any] { loginResponse }
    private var tokenExpiration: Date?
    private var loggedIn = false

    // Crypto
    private static let apiPublicKeyHex =
        "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let publicKey: P256.KeyAgreement.PublicKey
    private let sharedKey: Data

    init(
        email: String,
        password: String,
        countryId: String,
        configuration: ApiSessionConfiguration = ApiSessionConfiguration(),
        urlSession: URLSession = .shared
    ) throws {
        self.email = email
        self.countryId = countryId.uppercased()
        self.config = configuration
        self.urlSession = urlSession

        // Select API base by country
        if let base = ApiSession.resolveApiBase(countryId: self.countryId) {
            self.apiBase = base
        } else {
            self.apiBase = ApiServers.map["eu"] ?? ""
        }
        if self.apiBase.isEmpty {
            throw ApiSessionError.missingApiBase
        }

        // ECDH key pair + shared secret
        self.privateKey = P256.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
        let serverPub = try ApiSession.serverPublicKeyFromHex(Self.apiPublicKeyHex)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverPub)
        self.sharedKey = sharedSecret.withUnsafeBytes { Data($0) }

        // Store password securely later (Keychain). For now keep in memory only.
        self._password = password
    }

    // MARK: - Internal Password Storage

    private var _password: String

    // MARK: - Public API

    func updateCredentials(password: String, countryId: String) {
        self._password = password
        self.countryId = countryId.uppercased()
        if let base = ApiSession.resolveApiBase(countryId: self.countryId) {
            self.apiBase = base
        }
    }

    func generateHeader() -> [String: String] {
        var headers = ApiHeaders.base
        headers["country"] = countryId
        headers["timezone"] = ApiHelpers.getTimezoneGMTString()
        if let token, let gtoken {
            headers["x-auth-token"] = token
            headers["gtoken"] = gtoken
        }
        return headers
    }

    var isLoggedIn: Bool { loggedIn }

    func tokenExpiresAt() -> Date? {
        tokenExpiration
    }

    func tokenRemainingSeconds() -> TimeInterval? {
        tokenExpiration?.timeIntervalSinceNow
    }

    func hasValidToken(minimumSeconds: TimeInterval = 60) -> Bool {
        guard let token, !token.isEmpty, let expiration = tokenExpiration else {
            return false
        }
        return expiration.timeIntervalSinceNow > minimumSeconds
    }

    func hasValidCachedLogin(minimumSeconds: TimeInterval = 60) -> Bool {
        guard let cached = loadCachedLoginResponse() else { return false }
        return isCachedLoginValid(cached, minimumSeconds: minimumSeconds)
    }

    func authenticate(restart: Bool = false) async throws -> Bool {
        if restart {
            token = nil
            gtoken = nil
            tokenExpiration = nil
            loginResponse = [:]
            loggedIn = false
            nickname = ""
        }

        if !restart, let cached = loadCachedLoginResponse() {
            if isCachedLoginValid(cached, minimumSeconds: 60) {
                log("Using cached login response.")
                return applyLoginResponse(cached, cache: false)
            }
            log("Cached login response missing/expired; re-authenticating.")
        }

        let tzSeconds = TimeZone.current.secondsFromGMT()
        let payload: [String: Any] = [
            "ab": countryId,
            "client_secret_info": [
                "public_key": rawPublicKeyHex()
            ],
            "enc": 0,
            "email": email,
            "password": try encryptApiPassword(_password),
            "time_zone": tzSeconds * 1000,
            "transaction": ApiHelpers.generateTimestamp(inMilliseconds: true),
        ]

        let response: [String: Any]
        do {
            response = try await performRequest(
                method: "POST",
                endpoint: ApiLogin.path,
                headers: [:],
                json: payload
            )
        } catch {
            throw error
        }

        if let error = ApiErrorMapper.makeError(from: response, prefix: "Anker Api Error: login") {
            throw error
        }

        guard let data = response["data"] as? [String: Any] else {
            log("Login response missing data: \(response)")
            throw ApiSessionError.missingLoginData
        }

        return applyLoginResponse(data, cache: true)
    }

    func request(
        method: String,
        endpoint: String,
        headers: [String: String] = [:],
        json: [String: Any] = [:]
    ) async throws -> [String: Any] {
        // Refresh token if near expiry
        if let expiration = tokenExpiration, expiration.timeIntervalSinceNow < 60 {
            log("Access token expired or near expiry, re-authenticating.")
            _ = try await authenticate(restart: true)
        }

        // Ensure authenticated for non-login endpoints
        if endpoint != ApiLogin.path, !loggedIn {
            _ = try await authenticate()
        }

        do {
            let response = try await performRequest(
                method: method,
                endpoint: endpoint,
                headers: headers,
                json: json
            )

            if let error = ApiErrorMapper.makeError(from: response) {
                throw error
            }

            retryAttempt = nil
            return response
        } catch {
            if let apiError = error as? AnkerSolixError {
                switch apiError {
                case .requestLimit:
                    if retryAttempt != 429 && config.endpointLimit > 0 {
                        retryAttempt = 429
                        requestCount.addThrottle(endpoint: endpoint)
                        let sameRequests =
                            requestCount
                            .lastMinuteDetails()
                            .filter { $0.1.contains(endpoint) }
                        log(
                            "Api \(nickname) exceeded request limit with \(sameRequests.count) known requests in last minute, throttle will be enabled for endpoint: \(endpoint)"
                        )
                        try await enforceDelay(endpoint: endpoint)
                        return try await request(
                            method: method,
                            endpoint: endpoint,
                            headers: headers,
                            json: json
                        )
                    }
                case .busy:
                    if retryAttempt != 21105 {
                        retryAttempt = 21105
                        let delay = TimeInterval(Int.random(in: 2...5))
                        log(
                            "Server busy, retrying request of api \(nickname) after delay of \(delay) seconds for endpoint: \(endpoint)"
                        )
                        try await enforceDelay(delayOverride: delay)
                        return try await request(
                            method: method,
                            endpoint: endpoint,
                            headers: headers,
                            json: json
                        )
                    }
                default:
                    break
                }
            }

            if case ApiSessionError.httpStatus(let code, let body) = error {
                if code == 401 || code == 403, retryAttempt != code {
                    retryAttempt = code
                    log("Invalid login, retrying authentication for \(nickname). Response: \(body)")
                    _ = try await authenticate(restart: true)
                    return try await request(
                        method: method,
                        endpoint: endpoint,
                        headers: headers,
                        json: json
                    )
                }

                if code == 429 && retryAttempt != 429 && config.endpointLimit > 0 {
                    retryAttempt = 429
                    requestCount.addThrottle(endpoint: endpoint)
                    let sameRequests =
                        requestCount
                        .lastMinuteDetails()
                        .filter { $0.1.contains(endpoint) }
                    log(
                        "Api \(nickname) exceeded request limit with \(sameRequests.count) known requests in last minute, throttle will be enabled for endpoint: \(endpoint)"
                    )
                    try await enforceDelay(endpoint: endpoint)
                    return try await request(
                        method: method,
                        endpoint: endpoint,
                        headers: headers,
                        json: json
                    )
                }

                if [502, 504, 522].contains(code), retryAttempt != code {
                    retryAttempt = code
                    let delay = TimeInterval(Int.random(in: 2...5))
                    log(
                        "Http error '\(code)', retrying request of api \(nickname) after delay of \(delay) seconds for endpoint: \(endpoint)"
                    )
                    try await enforceDelay(delayOverride: delay)
                    return try await request(
                        method: method,
                        endpoint: endpoint,
                        headers: headers,
                        json: json
                    )
                }
            }

            retryAttempt = nil
            throw error
        }
    }

    func getMqttInfo() async throws -> [String: Any] {
        let response = try await request(
            method: "POST",
            endpoint: ApiEndpoints.powerService["get_mqtt_info"] ?? ""
        )
        return (response["data"] as? [String: Any]) ?? [:]
    }

    // MARK: - Request Execution

    private func performRequest(
        method: String,
        endpoint: String,
        headers: [String: String],
        json: [String: Any]
    ) async throws -> [String: Any] {
        let urlString = "\(apiBase)/\(endpoint)"
        guard let url = URL(string: urlString) else {
            throw ApiSessionError.invalidUrl(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = config.requestTimeout

        var mergedHeaders = generateHeader()
        headers.forEach { mergedHeaders[$0.key] = $0.value }
        mergedHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        if json.isEmpty {
            if request.httpMethod == "POST"
                || request.httpMethod == "PUT"
                || request.httpMethod == "PATCH"
            {
                request.httpBody = Data("{}".utf8)
            }
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
        }

        log("Request: \(request.httpMethod ?? "") \(urlString)")
        log("Request Headers: \(maskValues(mergedHeaders, keys: ["x-auth-token", "gtoken"]))")
        let maskedRequestBody = maskJsonValue(json)
        log("Request Body: \(maskedRequestBody)")
        let rawBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let maskedRawBody = maskJsonString(rawBody)
        log("Request Body Raw: \(maskedRawBody)")

        try await enforceDelay(endpoint: endpoint)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ApiSessionError.invalidResponse
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        log(
            "Response Status: \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
        )
        let maskedBodyText = maskJsonString(bodyText)
        log("Response Body: \(maskedBodyText)")
        if http.statusCode >= 400 {
            throw ApiSessionError.httpStatus(http.statusCode, bodyText)
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = jsonObject as? [String: Any] else {
            throw ApiSessionError.invalidJson
        }

        lastRequestTime = Date()
        requestCount.add(requestTime: lastRequestTime, requestInfo: "\(method) \(urlString)")

        return dict
    }

    private func enforceDelay(endpoint: String? = nil, delayOverride: TimeInterval? = nil)
        async throws
    {
        let rawDelay = delayOverride ?? config.requestDelay
        let delay = min(
            SolixDefaults.requestDelayMax,
            max(SolixDefaults.requestDelayMin, rawDelay)
        )

        var throttle: TimeInterval = 0
        if let endpoint,
            delayOverride == nil,
            config.endpointLimit > 0,
            requestCount.isThrottled(endpoint)
        {
            let sameRequests =
                requestCount
                .lastMinuteDetails()
                .filter { $0.1.contains(endpoint) }
            if sameRequests.count >= config.endpointLimit {
                throttle = 65 - Date().timeIntervalSince(sameRequests[0].0)
            }
            throttle = max(0, throttle)
            if throttle > 0 {
                let display = String(format: "%.1f", throttle)
                log(
                    "Throttling next request of api \(nickname) for \(display) seconds to maintain request limit of \(config.endpointLimit) for endpoint \(endpoint)"
                )
            }
        }

        let elapsed: TimeInterval
        if let last = lastRequestTime {
            elapsed = Date().timeIntervalSince(last)
        } else {
            elapsed = delayOverride == nil ? delay : 0
        }
        let wait = max(0, throttle, delay - elapsed)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    // MARK: - Crypto

    private func rawPublicKeyHex() -> String {
        let raw = publicKey.x963Representation
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    private static func serverPublicKeyFromHex(_ hex: String) throws -> P256.KeyAgreement.PublicKey
    {
        let data = Data(hexString: hex)
        return try P256.KeyAgreement.PublicKey(x963Representation: data)
    }

    private func encryptApiPassword(_ raw: String) throws -> String {
        let key = sharedKey
        guard key.count >= 32 else { throw ApiSessionError.encryptionFailed }
        let iv = key.prefix(16)
        guard let encrypted = AesCbcPkcs7.encrypt(data: Data(raw.utf8), key: key, iv: iv) else {
            throw ApiSessionError.encryptionFailed
        }
        return encrypted.base64EncodedString()
    }

    // MARK: - Logging & Masking

    private func log(_ message: String) {
        config.logger?(message)
    }

    private let sensitiveKeys: Set<String> = [
        "password",
        "passwd",
        "pass",
        "auth_token",
        "token",
        "gtoken",
        "email",
        "user",
        "user_id",
        "login",
        "account",
    ]

    private func maskValues(_ data: [String: String], keys: [String]) -> [String: String] {
        guard config.maskCredentials else { return data }
        var masked = data
        for key in keys {
            if let value = masked[key] {
                masked[key] = maskString(value)
            }
        }
        return masked
    }

    private func maskJsonValue(_ value: Any, key: String? = nil) -> Any {
        guard config.maskCredentials else { return value }
        if let dict = value as? [String: Any] {
            var masked: [String: Any] = [:]
            for (dictKey, dictValue) in dict {
                if sensitiveKeys.contains(dictKey.lowercased()) {
                    masked[dictKey] = maskString(String(describing: dictValue))
                } else {
                    masked[dictKey] = maskJsonValue(dictValue, key: dictKey)
                }
            }
            return masked
        }
        if let array = value as? [Any] {
            return array.map { maskJsonValue($0, key: key) }
        }
        if let key, sensitiveKeys.contains(key.lowercased()) {
            return maskString(String(describing: value))
        }
        return value
    }

    private func maskJsonString(_ body: String) -> String {
        guard config.maskCredentials else { return body }
        guard let data = body.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return body
        }
        let masked = maskJsonValue(jsonObject)
        guard let maskedData = try? JSONSerialization.data(withJSONObject: masked, options: []),
            let maskedString = String(data: maskedData, encoding: .utf8)
        else {
            return body
        }
        return maskedString
    }

    private func maskString(_ value: String) -> String {
        guard value.count > 4 else { return "####" }
        let prefix = value.prefix(2)
        let suffix = value.suffix(2)
        return "\(prefix)###masked###\(suffix)"
    }

    // MARK: - Auth Cache (UserDefaults)

    private func applyLoginResponse(_ data: [String: Any], cache: Bool) -> Bool {
        loginResponse = data
        token = data["auth_token"] as? String
        nickname = (data["nick_name"] as? String) ?? ""
        if let exp = data["token_expires_at"] as? TimeInterval {
            tokenExpiration = Date(timeIntervalSince1970: exp)
        } else {
            tokenExpiration = nil
        }

        if let userId = data["user_id"] as? String {
            gtoken = ApiHelpers.md5(userId)
            loggedIn = (token != nil)
        } else {
            gtoken = nil
            loggedIn = false
        }

        if loggedIn, cache {
            cacheLoginResponse(data)
        }

        return loggedIn
    }

    private func loadCachedLoginResponse() -> [String: Any]? {
        guard let jsonData = UserDefaults.standard.data(forKey: "SolixLoginResponse:\(email)")
        else {
            return nil
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
            return nil
        }
        return jsonObject as? [String: Any]
    }

    private func isCachedLoginValid(
        _ data: [String: Any],
        minimumSeconds: TimeInterval
    ) -> Bool {
        guard
            let token = data["auth_token"] as? String,
            !token.isEmpty,
            let exp = data["token_expires_at"] as? TimeInterval
        else {
            return false
        }
        let expiration = Date(timeIntervalSince1970: exp)
        return expiration.timeIntervalSinceNow > minimumSeconds
    }

    private func cacheLoginResponse(_ data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else {
            return
        }
        UserDefaults.standard.set(jsonData, forKey: "SolixLoginResponse:\(email)")
    }

    // MARK: - API Base Resolver

    private static func resolveApiBase(countryId: String) -> String? {
        for (region, countries) in ApiCountries.map where countries.contains(countryId) {
            if let base = ApiServers.map[region] { return base }
        }
        return nil
    }
}

// MARK: - AES CBC + PKCS7

enum AesCbcPkcs7 {
    static func encrypt(data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { return nil }
        var outData = Data(count: data.count + kCCBlockSizeAES128)
        let outDataCount = outData.count

        let result = outData.withUnsafeMutableBytes {
            outBytes -> (status: CCCryptorStatus, outLength: Int) in
            var outLength = 0
            let status = data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            outDataCount,
                            &outLength
                        )
                    }
                }
            }
            return (status, outLength)
        }

        guard result.status == kCCSuccess else { return nil }
        return outData.prefix(result.outLength)
    }
}

// MARK: - Data Hex Helper

extension Data {
    fileprivate init(hexString: String) {
        var data = Data()
        var temp = ""
        for (index, char) in hexString.enumerated() {
            temp.append(char)
            if index % 2 == 1 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                }
                temp = ""
            }
        }
        self = data
    }
}
