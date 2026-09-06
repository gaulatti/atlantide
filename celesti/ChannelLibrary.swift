import Foundation
import OSLog

enum CelestiChannelGroupKind: String, Decodable, Equatable {
    case collection
    case source
}

struct CelestiChannelGroupSummary: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let channelCount: Int
    let kind: CelestiChannelGroupKind
}

struct CelestiChannelGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let channels: [CelestiChannel]
    let total: Int
}

struct CelestiChannel: Decodable, Identifiable, Equatable {
    let id: String
    let tvgName: String
    let tvgLogo: String?
    let streamUrl: String
    let groupTitle: String?
}

private let channelLibraryLog = Logger(subsystem: "com.gaulatti.celesti", category: "ChannelLibrary")

private struct CelestiChannelPage: Decodable {
    let data: [CelestiChannel]
    let total: Int
    let page: Int
    let limit: Int
}

final class ChannelLibraryService {
    private let endpoint = URL(string: "https://api.celesti.gaulatti.com/channel-groups/for-device")!

    func groupSummaries(deviceID: String) async throws -> [CelestiChannelGroupSummary] {
        let url = endpoint.appendingPathComponent("summaries")
        var request = URLRequest(url: url)
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([CelestiChannelGroupSummary].self, from: data)
    }

    func channels(
        deviceID: String,
        group: CelestiChannelGroupSummary,
        page: Int,
        limit: Int = 100
    ) async throws -> CelestiChannelGroup {
        var components = URLComponents(
            url: endpoint
                .appendingPathComponent(group.id)
                .appendingPathComponent("channels"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let result = try JSONDecoder().decode(CelestiChannelPage.self, from: data)
        for channel in result.data {
            guard let url = URL(string: channel.streamUrl), url.scheme != nil else {
                channelLibraryLog.error("Channel \(channel.id, privacy: .public) has an invalid authoritative stream URL")
                throw URLError(.badURL)
            }
        }
        return CelestiChannelGroup(id: group.id, name: group.name, channels: result.data, total: result.total)
    }
}
