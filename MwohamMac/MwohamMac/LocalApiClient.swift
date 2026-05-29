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

    enum CodingKeys: String, CodingKey {
        case status
        case currentApp = "current_app"
        case currentWindow = "current_window"
        case meetingMode = "meeting_mode"
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
        apiToken: String? = nil,
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

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalApiClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LocalApiClientError.badStatusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
