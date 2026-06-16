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
    let currentMeeting: MeetingResponse?
    let sessionStartedAt: String?
    let elapsedSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case currentApp = "current_app"
        case currentWindow = "current_window"
        case meetingMode = "meeting_mode"
        case currentMeeting = "current_meeting"
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

struct MeetingStartRequest: Encodable {
    let title: String?
    let meetingApp: String?
    let transcriptEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case meetingApp = "meeting_app"
        case transcriptEnabled = "transcript_enabled"
    }
}

struct MeetingEndRequest: Encodable {
    let summary: String?
}

struct MeetingTranscriptCreateRequest: Encodable {
    let meetingSessionId: Int?
    let text: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case meetingSessionId = "meeting_session_id"
        case text
        case source
    }
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

struct ScreenObservationCreateRequest: Encodable {
    let timestamp: String
    let appName: String?
    let windowTitle: String?
    let ocrText: String?
    let detectedKeywords: [String]?
    let aiInference: String?
    let frameHash: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case appName = "app_name"
        case windowTitle = "window_title"
        case ocrText = "ocr_text"
        case detectedKeywords = "detected_keywords"
        case aiInference = "ai_inference"
        case frameHash = "frame_hash"
    }
}

struct DailyReportCreateRequest: Encodable {
    let mode: String
}

struct ReportUpdateRequest: Encodable {
    let title: String?
    let content: String?
}

struct PrivateAppResponse: Decodable {
    let id: Int
    let appName: String
    let matchType: String
    let isEnabled: Bool
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case appName = "app_name"
        case matchType = "match_type"
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
    }
}

struct PrivateAppListResponse: Decodable {
    let items: [PrivateAppResponse]
    let total: Int
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

struct MeetingResponse: Decodable {
    let id: Int
    let sessionId: Int
    let startedAt: String
    let endedAt: String?
    let status: String
    let meetingApp: String?
    let title: String?
    let transcriptEnabled: Bool
    let summary: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case status
        case meetingApp = "meeting_app"
        case title
        case transcriptEnabled = "transcript_enabled"
        case summary
        case createdAt = "created_at"
    }
}

struct MeetingTranscriptResponse: Decodable {
    let id: Int
    let meetingSessionId: Int?
    let text: String
    let source: String
    let startedAt: String?
    let endedAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingSessionId = "meeting_session_id"
        case text
        case source
        case startedAt = "started_at"
        case endedAt = "ended_at"
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

struct ScreenObservationCreateResponse: Decodable {
    let id: Int
    let saved: Bool
    let duplicate: Bool
}

struct BackendSnapshot {
    let health: HealthResponse
    let status: StatusResponse
}

struct TimelineResponse: Decodable {
    let date: String
    let items: [TimelineItemResponse]
    let total: Int
}

struct TimelineItemResponse: Decodable, Identifiable {
    let type: String
    let id: Int
    let timestamp: String
    let content: String
    let displayLabel: String?
    let source: String?
    let eventType: String?
    let appName: String?
    let windowTitle: String?
    let meetingId: Int?
    let speaker: String?
    let confidence: Double?
    let sessionId: Int?
    let linkedType: String?
    let linkedId: Int?
    let repoPath: String?
    let branch: String?
    let command: String?
    let status: String?
    let endedAt: String?
    let durationSeconds: Int?
    let sampleCount: Int?
    let displayTitle: String?
    let signalLevel: String?
    let hiddenByDefault: Bool?
    let noiseReason: String?
    let eventCount: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case timestamp
        case content
        case displayLabel = "display_label"
        case source
        case eventType = "event_type"
        case appName = "app_name"
        case windowTitle = "window_title"
        case meetingId = "meeting_id"
        case speaker
        case confidence
        case sessionId = "session_id"
        case linkedType = "linked_type"
        case linkedId = "linked_id"
        case repoPath = "repo_path"
        case branch
        case command
        case status
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case sampleCount = "sample_count"
        case displayTitle = "display_title"
        case signalLevel = "signal_level"
        case hiddenByDefault = "hidden_by_default"
        case noiseReason = "noise_reason"
        case eventCount = "event_count"
    }
}

struct ReportResponse: Decodable, Identifiable, Equatable {
    let id: Int
    let projectId: Int?
    let date: String?
    let mode: String
    let title: String?
    let content: String
    let sourceRangeStart: String?
    let sourceRangeEnd: String?
    let createdBy: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case date
        case mode
        case title
        case content
        case sourceRangeStart = "source_range_start"
        case sourceRangeEnd = "source_range_end"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ReportListResponse: Decodable {
    let items: [ReportResponse]
    let total: Int
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

    func fetchHealth() async throws -> HealthResponse {
        var request = makeRequest(path: "/health")
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func fetchTimelineDetail(date: String? = nil) async throws -> TimelineResponse {
        var request = makeRequest(path: "/timeline/today/detail")
        if let date, !date.isEmpty {
            var components = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "date", value: date)]
            if let url = components?.url {
                request.url = url
            }
        }
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    func fetchTodayReports(mode: String? = nil) async throws -> ReportListResponse {
        var request = makeRequest(path: "/reports/today")
        request.url = urlWithQueryItems(
            request.url!,
            queryItems: [
                mode.map { URLQueryItem(name: "mode", value: $0) },
            ].compactMap { $0 }
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    func fetchReports(limit: Int = 20) async throws -> ReportListResponse {
        var request = makeRequest(path: "/reports")
        request.url = urlWithQueryItems(
            request.url!,
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    func fetchReport(id: Int) async throws -> ReportResponse {
        try await get("/reports/\(id)")
    }

    @discardableResult
    func createDailyReport(mode: String) async throws -> ReportResponse {
        try await post(
            "/reports/daily",
            body: DailyReportCreateRequest(mode: mode)
        )
    }

    @discardableResult
    func updateReport(
        id: Int,
        title: String? = nil,
        content: String? = nil
    ) async throws -> ReportResponse {
        try await patch(
            "/reports/\(id)",
            body: ReportUpdateRequest(title: title, content: content)
        )
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
    func startMeeting(title: String? = nil) async throws -> MeetingResponse {
        try await post(
            "/meetings/start",
            body: MeetingStartRequest(
                title: title,
                meetingApp: "MwohamMac",
                transcriptEnabled: true
            )
        )
    }

    @discardableResult
    func endMeeting(id: Int, summary: String? = nil) async throws -> MeetingResponse {
        try await post(
            "/meetings/\(id)/end",
            body: MeetingEndRequest(summary: summary)
        )
    }

    func fetchCurrentMeeting() async throws -> MeetingResponse? {
        try await get("/meetings/current")
    }

    @discardableResult
    func createMeetingTranscript(
        meetingSessionId: Int?,
        text: String,
        source: String = "apple_speech"
    ) async throws -> MeetingTranscriptResponse {
        try await post(
            "/meeting-transcripts",
            body: MeetingTranscriptCreateRequest(
                meetingSessionId: meetingSessionId,
                text: text,
                source: source
            )
        )
    }

    func fetchPrivateApps() async throws -> [PrivateAppResponse] {
        let response: PrivateAppListResponse = try await get("/settings/private-apps")
        return response.items
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

    @discardableResult
    func createScreenObservation(
        appName: String?,
        windowTitle: String?,
        ocrText: String,
        detectedKeywords: [String]?,
        aiInference: String?,
        frameHash: String?,
        timestamp: Date = Date()
    ) async throws -> ScreenObservationCreateResponse {
        try await post(
            "/screen-observations",
            body: ScreenObservationCreateRequest(
                timestamp: Self.eventTimestampFormatter.string(from: timestamp),
                appName: appName,
                windowTitle: windowTitle,
                ocrText: ocrText,
                detectedKeywords: detectedKeywords,
                aiInference: aiInference,
                frameHash: frameHash
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

    private func urlWithQueryItems(
        _ url: URL,
        queryItems: [URLQueryItem]
    ) -> URL {
        guard !queryItems.isEmpty else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
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
