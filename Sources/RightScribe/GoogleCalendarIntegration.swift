import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct CalendarAttendeeSnapshot: Codable, Equatable, Identifiable, Sendable {
    let name: String?
    let email: String
    let responseStatus: String?
    let isOrganizer: Bool
    let isSelf: Bool

    var id: String { email.lowercased() }
    var displayName: String { name?.isEmpty == false ? name! : email }
}

struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    let provider: String
    let eventIdentifier: String
    let title: String
    let calendarIdentifier: String
    let startDate: Date
    let endDate: Date
    let meetingURL: String?
    let organizerEmail: String?
    let attendees: [CalendarAttendeeSnapshot]
}

enum GoogleCalendarConnectionState: Equatable {
    case notConfigured
    case disconnected
    case connecting
    case connected(String?)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

actor GoogleCalendarService {
    enum ServiceError: LocalizedError {
        case clientIDMissing
        case invalidClientID
        case browserCouldNotOpen
        case authorizationCancelled
        case authorizationFailed(String)
        case callbackTimedOut
        case invalidResponse
        case tokenUnavailable

        var errorDescription: String? {
            switch self {
            case .clientIDMissing:
                return "Add the Google OAuth client ID for RightScribe first."
            case .invalidClientID:
                return "That doesn't look like a Google OAuth client ID."
            case .browserCouldNotOpen:
                return "RightScribe couldn't open Google sign-in in your browser."
            case .authorizationCancelled:
                return "Google Calendar connection was cancelled."
            case .authorizationFailed(let reason):
                return "Google authorization failed: \(reason)"
            case .callbackTimedOut:
                return "Google sign-in took too long. Please try connecting again."
            case .invalidResponse:
                return "Google returned an unreadable response."
            case .tokenUnavailable:
                return "Google Calendar needs to be connected again."
            }
        }
    }

    private static let clientIDKey = "RightScribe.googleOAuthClientID"
    private static let keychainService = "com.karimsaad.rightscribe.google-calendar"
    private static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let encoder = JSONEncoder()

    nonisolated static var configuredClientID: String {
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
           !bundled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return UserDefaults.standard.string(forKey: clientIDKey) ?? ""
    }

    nonisolated static func saveClientID(_ value: String) {
        UserDefaults.standard.set(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: clientIDKey
        )
    }

    nonisolated static var hasStoredConnection: Bool {
        guard !configuredClientID.isEmpty else { return false }
        return GoogleCalendarKeychain.load(service: keychainService, account: configuredClientID) != nil
    }

    func connect(clientID rawClientID: String) async throws -> String? {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw ServiceError.clientIDMissing }
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw ServiceError.invalidClientID
        }
        Self.saveClientID(clientID)

        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)
        let callbackServer = try OAuthLoopbackServer()
        let redirectURI = try await callbackServer.start()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizationURL = components.url else { throw ServiceError.invalidResponse }

        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else {
            callbackServer.cancel()
            throw ServiceError.browserCouldNotOpen
        }

        let callbackURL = try await withThrowingTaskGroup(of: URL.self) { group in
            defer {
                callbackServer.cancel()
                group.cancelAll()
            }
            group.addTask { try await callbackServer.waitForCallback() }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw ServiceError.callbackTimedOut
            }
            guard let first = try await group.next() else { throw ServiceError.callbackTimedOut }
            return first
        }

        let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let values = (callback?.queryItems ?? []).reduce(into: [String: String]()) {
            $0[$1.name] = $1.value ?? ""
        }
        guard values["state"] == state else {
            throw ServiceError.authorizationFailed("The security state did not match.")
        }
        if let error = values["error"] {
            if error == "access_denied" { throw ServiceError.authorizationCancelled }
            throw ServiceError.authorizationFailed(error)
        }
        guard let code = values["code"], !code.isEmpty else { throw ServiceError.invalidResponse }

        let tokenResponse = try await exchangeAuthorizationCode(
            code,
            clientID: clientID,
            redirectURI: redirectURI,
            verifier: verifier
        )
        let token = GoogleStoredToken(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
        try saveToken(token, clientID: clientID)
        return try await primaryCalendarIdentifier(token: token)
    }

    func disconnect() {
        let clientID = Self.configuredClientID
        guard !clientID.isEmpty else { return }
        GoogleCalendarKeychain.delete(service: Self.keychainService, account: clientID)
    }

    func connectedAccountIdentifier() async -> String? {
        guard !Self.configuredClientID.isEmpty,
              let token = loadToken(clientID: Self.configuredClientID) else { return nil }
        return try? await primaryCalendarIdentifier(token: token)
    }

    func matchingEvent(at date: Date, meetingFamily: String) async -> CalendarEventSnapshot? {
        let clientID = Self.configuredClientID
        guard !clientID.isEmpty else { return nil }
        do {
            let token = try await validToken(clientID: clientID)
            let events = try await events(around: date, token: token)
            return Self.bestMatch(in: events, at: date, meetingFamily: meetingFamily)
        } catch {
            return nil
        }
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        clientID: String,
        redirectURI: URL,
        verifier: String
    ) async throws -> GoogleTokenResponse {
        try await tokenRequest([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
            "grant_type": "authorization_code"
        ])
    }

    private func refresh(_ token: GoogleStoredToken, clientID: String) async throws -> GoogleStoredToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw ServiceError.tokenUnavailable
        }
        let response: GoogleTokenResponse = try await tokenRequest([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        let refreshed = GoogleStoredToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        try saveToken(refreshed, clientID: clientID)
        return refreshed
    }

    private func tokenRequest<T: Decodable>(_ fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(fields).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let reason = (try? JSONDecoder().decode(GoogleErrorResponse.self, from: data).errorDescription)
                ?? "token request rejected"
            throw ServiceError.authorizationFailed(reason)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func validToken(clientID: String) async throws -> GoogleStoredToken {
        guard let token = loadToken(clientID: clientID) else { throw ServiceError.tokenUnavailable }
        if token.expiresAt.timeIntervalSinceNow > 60 { return token }
        return try await refresh(token, clientID: clientID)
    }

    private func primaryCalendarIdentifier(token: GoogleStoredToken) async throws -> String? {
        let clientID = Self.configuredClientID
        let valid = token.expiresAt.timeIntervalSinceNow > 60
            ? token
            : try await refresh(token, clientID: clientID)
        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary")!
        )
        request.timeoutInterval = 12
        request.setValue("Bearer \(valid.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
        return try decoder.decode(GoogleCalendarListEntry.self, from: data).id
    }

    private func events(around date: Date, token: GoogleStoredToken) async throws -> [GoogleCalendarEvent] {
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/primary/events"
        )!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: date.addingTimeInterval(-6 * 60 * 60))),
            URLQueryItem(name: "timeMax", value: formatter.string(from: date.addingTimeInterval(6 * 60 * 60))),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ServiceError.tokenUnavailable
        }
        return try decoder.decode(GoogleEventsResponse.self, from: data).items
    }

    private func loadToken(clientID: String) -> GoogleStoredToken? {
        guard let data = GoogleCalendarKeychain.load(
            service: Self.keychainService,
            account: clientID
        ) else { return nil }
        return try? decoder.decode(GoogleStoredToken.self, from: data)
    }

    private func saveToken(_ token: GoogleStoredToken, clientID: String) throws {
        let data = try encoder.encode(token)
        try GoogleCalendarKeychain.save(
            data,
            service: Self.keychainService,
            account: clientID
        )
    }

    static func bestMatch(
        in events: [GoogleCalendarEvent],
        at date: Date,
        meetingFamily: String
    ) -> CalendarEventSnapshot? {
        let candidates = events.compactMap { event -> (Int, CalendarEventSnapshot)? in
            guard event.status != "cancelled",
                  let start = event.start.resolvedDate,
                  let end = event.end.resolvedDate,
                  event.start.dateTime != nil,
                  start <= date.addingTimeInterval(15 * 60),
                  end >= date.addingTimeInterval(-15 * 60) else { return nil }

            let rawConferenceText = [event.hangoutLink, event.location, event.description]
                .compactMap { $0 }
                .joined(separator: " ")
            let conferenceText = rawConferenceText.lowercased()
            var score = start <= date && end >= date ? 100 : 40
            score -= min(30, Int(abs(date.timeIntervalSince(start)) / 60))
            if conferenceText.contains(Self.conferenceNeedle(for: meetingFamily)) { score += 35 }
            if event.attendees?.contains(where: { $0.selfValue == true }) == true { score += 5 }

            let attendees = (event.attendees ?? []).compactMap { attendee -> CalendarAttendeeSnapshot? in
                guard let email = attendee.email, !email.isEmpty else { return nil }
                return CalendarAttendeeSnapshot(
                    name: attendee.displayName,
                    email: email,
                    responseStatus: attendee.responseStatus,
                    isOrganizer: attendee.organizer ?? false,
                    isSelf: attendee.selfValue ?? false
                )
            }
            return (score, CalendarEventSnapshot(
                provider: "Google Calendar",
                eventIdentifier: event.id,
                title: event.summary ?? "Calendar meeting",
                calendarIdentifier: "primary",
                startDate: start,
                endDate: end,
                meetingURL: event.hangoutLink ?? Self.firstURL(in: rawConferenceText),
                organizerEmail: event.organizer?.email,
                attendees: attendees
            ))
        }
        return candidates.max(by: { $0.0 < $1.0 })?.1
    }

    private static func conferenceNeedle(for family: String) -> String {
        switch family {
        case "zoom": return "zoom"
        case "teams": return "teams"
        case "webex": return "webex"
        case "browser": return "meet.google"
        default: return family
        }
    }

    private static func firstURL(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>[](){}.,;\"'"))
        }.first { value in
            value.hasPrefix("https://") || value.hasPrefix("http://")
        }
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(formEscape(key))=\(formEscape(value))"
        }.joined(separator: "&")
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct GoogleStoredToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct GoogleErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct GoogleCalendarEvent: Decodable, Sendable {
    struct EventDate: Decodable, Sendable {
        let dateTime: String?
        let date: String?

        var resolvedDate: Date? {
            guard let dateTime else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateTime) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: dateTime)
        }
    }

    struct Attendee: Decodable, Sendable {
        let email: String?
        let displayName: String?
        let responseStatus: String?
        let organizer: Bool?
        let selfValue: Bool?

        enum CodingKeys: String, CodingKey {
            case email, displayName, responseStatus, organizer
            case selfValue = "self"
        }
    }

    struct Organizer: Decodable, Sendable { let email: String? }

    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let hangoutLink: String?
    let start: EventDate
    let end: EventDate
    let organizer: Organizer?
    let attendees: [Attendee]?
}

private struct GoogleEventsResponse: Decodable { let items: [GoogleCalendarEvent] }
private struct GoogleCalendarListEntry: Decodable { let id: String }

private enum GoogleCalendarKeychain {
    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private final class OAuthLoopbackServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case unavailable
        case invalidCallback

        var errorDescription: String? {
            switch self {
            case .unavailable: return "RightScribe couldn't start the private Google sign-in callback."
            case .invalidCallback: return "Google returned an invalid sign-in callback."
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.karimsaad.rightscribe.google-oauth")
    private let lock = NSLock()
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var bufferedCallback: Result<URL, Error>?
    private var startCompleted = false
    private var cancelled = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    guard !self.startCompleted else {
                        self.lock.unlock()
                        return
                    }
                    self.startCompleted = true
                    self.lock.unlock()
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback") else {
                        continuation.resume(throwing: ServerError.unavailable)
                        return
                    }
                    continuation.resume(returning: url)
                case .failed(let error):
                    self.lock.lock()
                    guard !self.startCompleted else {
                        self.lock.unlock()
                        return
                    }
                    self.startCompleted = true
                    self.lock.unlock()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            if let bufferedCallback {
                self.bufferedCallback = nil
                lock.unlock()
                continuation.resume(with: bufferedCallback)
            } else {
                callbackContinuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.components(separatedBy: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init)
            let callback = path.flatMap { URL(string: "http://127.0.0.1\($0)") }
            let succeeded = callback != nil
            let body = succeeded
                ? "<html><body><h2>RightScribe is connected.</h2><p>You can close this tab.</p></body></html>"
                : "<html><body><h2>RightScribe couldn't complete sign-in.</h2></body></html>"
            let response = "HTTP/1.1 \(succeeded ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.complete(callback.map(Result.success) ?? .failure(ServerError.invalidCallback))
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            bufferedCallback = result
            lock.unlock()
        }
    }
}
