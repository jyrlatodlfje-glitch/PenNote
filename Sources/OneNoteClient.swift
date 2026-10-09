import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct OneNoteSection: Identifiable, Decodable, Hashable {
    struct Notebook: Decodable, Hashable {
        let displayName: String?
    }

    let id: String
    let displayName: String
    let parentNotebook: Notebook?

    var label: String {
        [parentNotebook?.displayName, displayName].compactMap { $0 }.joined(separator: " › ")
    }
}

struct OneNoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "PenNote",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var item = query(key)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Microsoft 개인 계정으로 로그인해 OneNote에 페이지를 만든다 (Microsoft Graph).
@MainActor
final class OneNoteClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OneNoteClient()

    /// Microsoft Entra에 등록한 앱의 Application (client) ID
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "oneNoteClientID") }
    }
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var sectionID: String
    @Published private(set) var sectionName: String

    private let authority = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
    private let redirect = "pennote://auth"
    private let scope = "Notes.ReadWrite offline_access"
    private let refreshKey = "oneNoteRefreshToken"
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var session: ASWebAuthenticationSession?

    override init() {
        let defaults = UserDefaults.standard
        clientID = defaults.string(forKey: "oneNoteClientID") ?? ""
        sectionID = defaults.string(forKey: "oneNoteSectionID") ?? ""
        sectionName = defaults.string(forKey: "oneNoteSectionName") ?? ""
        isSignedIn = Keychain.get("oneNoteRefreshToken") != nil
        super.init()
    }

    var isReady: Bool { isSignedIn && !sectionID.isEmpty }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }

    func signIn() async throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw OneNoteError(message: "앱 등록 ID를 먼저 입력하세요.") }

        // PKCE: 비밀 키 없이 로그인 결과가 이 앱의 요청에 대한 것임을 증명한다.
        let verifier = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: authority + "/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let authorizeURL = components.url!

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: "pennote") { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? OneNoteError(message: "로그인이 취소되었습니다."))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let reason = items.first(where: { $0.name == "error_description" })?.value ?? "로그인에 실패했습니다."
            throw OneNoteError(message: reason)
        }
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ])
    }

    func signOut() {
        Keychain.set(nil, for: refreshKey)
        accessToken = nil
        expiry = .distantPast
        isSignedIn = false
    }

    func select(_ section: OneNoteSection) {
        sectionID = section.id
        sectionName = section.label
        UserDefaults.standard.set(sectionID, forKey: "oneNoteSectionID")
        UserDefaults.standard.set(sectionName, forKey: "oneNoteSectionName")
    }

    func sections() async throws -> [OneNoteSection] {
        struct Response: Decodable {
            let value: [OneNoteSection]
        }
        let url = "https://graph.microsoft.com/v1.0/me/onenote/sections"
            + "?$select=id,displayName&$expand=parentNotebook($select=displayName)&$top=100"
        var request = URLRequest(url: URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return try JSONDecoder().decode(Response.self, from: try await send(request)).value
            .sorted { $0.label < $1.label }
    }

    func createPage(_ page: OneNotePage) async throws {
        guard !sectionID.isEmpty else { throw OneNoteError(message: "보낼 섹션을 먼저 고르세요.") }
        let boundary = "PenNote-\(UUID().uuidString)"
        var body = Data()
        func part(name: String, type: String, data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        part(name: "Presentation", type: "text/html", data: Data(page.html.utf8))
        for file in page.files {
            part(name: file.name, type: file.type, data: file.data)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/onenote/sections/\(sectionID)/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await send(request)
    }

    private func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let refresh = Keychain.get(refreshKey) else {
            isSignedIn = false
            throw OneNoteError(message: "OneNote에 다시 로그인해 주세요.")
        }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let accessToken else { throw OneNoteError(message: "OneNote에 다시 로그인해 주세요.") }
        return accessToken
    }

    private func requestToken(_ parameters: [String: String]) async throws {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        var fields = parameters
        fields["client_id"] = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        fields["scope"] = scope
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let form = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")

        var request = URLRequest(url: URL(string: authority + "/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)
        let response = try JSONDecoder().decode(Response.self, from: try await send(request))
        accessToken = response.access_token
        expiry = Date().addingTimeInterval(response.expires_in)
        if let refresh = response.refresh_token {
            Keychain.set(refresh, for: refreshKey)
        }
        isSignedIn = true
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw OneNoteError(message: "Microsoft 서버가 요청을 거절했습니다. \(detail)")
        }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
