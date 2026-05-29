//
//  LocalApiClient.swift
//  MwohamMac
//
//  Created by Codex on 5/29/26.
//

import Foundation

struct HealthResponse: Decodable {
    let status: String
    let version: String?
    let database: String?
}

struct StatusResponse: Decodable {
    let status: String
    let currentApp: String?
    let currentWindow: String?
    let meetingMode: Bool
    let sessionStartedAt: String?
    let elapsedSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case currentApp = "current_app"
        case currentWindow = "current_window"
        case meetingMode = "meeting_mode"
        case sessionStartedAt = "session_started_at"
        case elapsedSeconds = "elapsed_seconds"
    }
}

struct RecordingResponse: Decodable {
    let sessionId: Int
    let status: String
    let startedAt: String
    let endedAt: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct MemoCreateRequest: Encodable {
    let content: String
}

struct WorkEventCreateRequest: Encodable {
    let timestamp: String
    let source: String
    let appName: String?
    let windowTitle: String?
    let content: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case source
        case appName = "app_name"
        case windowTitle = "window_title"
        case content
    }
}

struct ActivitySegmentCreateRequest: Encodable {
    let appName: String?
    let windowTitle: String?
    let source: String
    let startedAt: String
    let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case windowTitle = "window_title"
        case source
        case startedAt = "started_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct ActivitySegmentUpdateRequest: Encodable {
    let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case lastSeenAt = "last_seen_at"
    }
}

struct MemoResponse: Decodable {
    let id: Int
    let sessionId: Int?
    let timestamp: String
    let content: String
    let linkedType: String?
    let linkedId: Int?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case timestamp
        case content
        case linkedType = "linked_type"
        case linkedId = "linked_id"
        case createdAt = "created_at"
    }
}

struct WorkEventCreateResponse: Decodable {
    let id: Int
    let saved: Bool
    let duplicate: Bool
}

struct ActivitySegmentResponse: Decodable {
    let id: Int?
    let sessionId: Int?
    let appName: String?
    let windowTitle: String?
    let source: String
    let startedAt: String
    let endedAt: String
    let lastSeenAt: String
    let durationSeconds: Int
    let sampleCount: Int
    let createdAt: String
    let saved: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case source
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case lastSeenAt = "last_seen_at"
        case durationSeconds = "duration_seconds"
        case sampleCount = "sample_count"
        case createdAt = "created_at"
        case saved
    }
}

struct BackendSnapshot {
    let health: HealthResponse
    let status: StatusResponse
}

enum LocalApiClientError: LocalizedError {
    case invalidResponse
    case badStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "서버 응답을 확인할 수 없습니다."
        case .badStatusCode(let statusCode):
            return "서버가 오류 상태를 반환했습니다. HTTP \(statusCode)"
        }
    }
}

final class LocalApiClient {
    private let baseURL: URL
    private let urlSession: URLSession
    var apiToken: String?

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!,
        apiToken: String? = ProcessInfo.processInfo.environment["LOCAL_API_TOKEN"],
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.urlSession = urlSession
    }

    func fetchSnapshot() async throws -> BackendSnapshot {
        let health: HealthResponse = try await get("/health")
        let status: StatusResponse = try await get("/status")

        return BackendSnapshot(health: health, status: status)
    }

    @discardableResult
    func startRecording() async throws -> RecordingResponse {
        try await post("/recording/start")
    }

    @discardableResult
    func pauseRecording() async throws -> RecordingResponse {
        try await post("/recording/pause")
    }

    @discardableResult
    func resumeRecording() async throws -> RecordingResponse {
        try await post("/recording/resume")
    }

    @discardableResult
    func stopRecording() async throws -> RecordingResponse {
        try await post("/recording/stop")
    }

    @discardableResult
    func createMemo(content: String) async throws -> MemoResponse {
        try await post("/memos", body: MemoCreateRequest(content: content))
    }

    @discardableResult
    func createEvent(
        appName: String?,
        windowTitle: String?,
        source: String,
        content: String,
        timestamp: Date = Date()
    ) async throws -> WorkEventCreateResponse {
        try await post(
            "/events",
            body: WorkEventCreateRequest(
                timestamp: Self.eventTimestampFormatter.string(from: timestamp),
                source: source,
                appName: appName,
                windowTitle: windowTitle,
                content: content
            )
        )
    }

    @discardableResult
    func createActivitySegment(
        appName: String?,
        windowTitle: String?,
        source: String,
        startedAt: Date,
        lastSeenAt: Date
    ) async throws -> ActivitySegmentResponse {
        try await post(
            "/activity-segments",
            body: ActivitySegmentCreateRequest(
                appName: appName,
                windowTitle: windowTitle,
                source: source,
                startedAt: Self.eventTimestampFormatter.string(from: startedAt),
                lastSeenAt: Self.eventTimestampFormatter.string(from: lastSeenAt)
            )
        )
    }

    @discardableResult
    func updateActivitySegment(
        id: Int,
        lastSeenAt: Date
    ) async throws -> ActivitySegmentResponse {
        try await patch(
            "/activity-segments/\(id)",
            body: ActivitySegmentUpdateRequest(
                lastSeenAt: Self.eventTimestampFormatter.string(from: lastSeenAt)
            )
        )
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var request = makeRequest(path: path)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    private func post<Response: Decodable>(_ path: String) async throws -> Response {
        var request = makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        return try await send(request)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    private func patch<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = makeRequest(path: path)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    private func makeRequest(path: String) -> URLRequest {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)

        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalApiClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LocalApiClientError.badStatusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static let eventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
