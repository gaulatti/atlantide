import Foundation
import Testing
@testable import AtlantideResilience

@Test func smartSummaryDecodesFirstWithAnAccessibleRankingIcon() async throws {
    let client = ScriptedChannelLibraryClient(responses: [
        .json(
            """
            [
              {"id":"smart:most-viewed","name":"Most viewed","channelCount":2,"kind":"smart"},
              {"id":"collection-a","name":"Favorites","channelCount":1,"kind":"collection"},
              {"id":"source:bmV3cw","name":"News","channelCount":3,"kind":"source"}
            ]
            """
        ),
    ])
    let service = ChannelLibraryService(
        endpoint: URL(string: "http://localhost:3000/channel-groups/for-device")!,
        client: client
    )

    let summaries = try await service.groupSummaries(deviceID: "LOCAL-OPERATOR-TV")

    #expect(summaries.map(\.id) == ["smart:most-viewed", "collection-a", "source:bmV3cw"])
    #expect(summaries.map(\.kind) == [.smart, .collection, .source])
    #expect(summaries.map { $0.kind.systemImage } == ["chart.bar.fill", "rectangle.stack.fill", "tray.full.fill"])
    let requests = await client.requests
    #expect(requests.count == 1)
    #expect(requests[0].url?.path == "/channel-groups/for-device/summaries")
    #expect(requests[0].value(forHTTPHeaderField: "X-Device-ID") == "LOCAL-OPERATOR-TV")
}

@Test func absentSmartSummaryLeavesExistingKindsAndOrderUnchanged() async throws {
    let client = ScriptedChannelLibraryClient(responses: [
        .json(
            """
            [
              {"id":"collection-a","name":"Favorites","channelCount":1,"kind":"collection"},
              {"id":"source:bmV3cw","name":"News","channelCount":3,"kind":"source"}
            ]
            """
        ),
    ])
    let service = ChannelLibraryService(
        endpoint: URL(string: "http://localhost:3000/channel-groups/for-device")!,
        client: client
    )

    let summaries = try await service.groupSummaries(deviceID: "LOCAL-OPERATOR-TV")

    #expect(summaries.map(\.id) == ["collection-a", "source:bmV3cw"])
    #expect(summaries.map(\.kind) == [.collection, .source])
}

@Test func smartPagesUseTheGenericEndpointAndPreserveServerRankingAcrossMerge() async throws {
    let client = ScriptedChannelLibraryClient(responses: [
        .json(channelPage(ids: ["rank-1", "rank-2"], total: 3, page: 1, limit: 2)),
        .json(channelPage(ids: ["rank-3"], total: 3, page: 2, limit: 2)),
    ])
    let service = ChannelLibraryService(
        endpoint: URL(string: "http://localhost:3000/channel-groups/for-device")!,
        client: client
    )
    let summary = CelestiChannelGroupSummary(
        id: "smart:most-viewed",
        name: "Most viewed",
        channelCount: 3,
        kind: .smart
    )

    let first = try await service.channels(deviceID: "LOCAL-OPERATOR-TV", group: summary, page: 1, limit: 2)
    let second = try await service.channels(deviceID: "LOCAL-OPERATOR-TV", group: summary, page: 2, limit: 2)
    let merged = first.appendingPage(second)

    #expect(merged.channels.map(\.id) == ["rank-1", "rank-2", "rank-3"])
    #expect(merged.total == 3)
    let requests = await client.requests
    #expect(requests.map { $0.url?.path } == [
        "/channel-groups/for-device/smart:most-viewed/channels",
        "/channel-groups/for-device/smart:most-viewed/channels",
    ])
    #expect(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems == [
        URLQueryItem(name: "page", value: "1"),
        URLQueryItem(name: "limit", value: "2"),
    ])
    #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems == [
        URLQueryItem(name: "page", value: "2"),
        URLQueryItem(name: "limit", value: "2"),
    ])
}

@Test func explicitRadioMediumSurvivesChannelLibraryDecoding() async throws {
    let client = ScriptedChannelLibraryClient(responses: [
        .json(
            """
            {"data":[{"id":"radio-one","tvgName":"Radio One","tvgLogo":null,"streamUrl":"https://media.invalid/radio.mp3","groupTitle":"Radio","medium":"radio"}],"total":1,"page":1,"limit":20}
            """
        ),
    ])
    let service = ChannelLibraryService(
        endpoint: URL(string: "http://localhost:3000/channel-groups/for-device")!,
        client: client
    )
    let summary = CelestiChannelGroupSummary(
        id: "collection-radio",
        name: "Radio",
        channelCount: 1,
        kind: .collection
    )

    let page = try await service.channels(
        deviceID: "LOCAL-OPERATOR-TV",
        group: summary,
        page: 1,
        limit: 20
    )

    #expect(page.channels.first?.medium == .radio)
}

@Test func debugAPIBaseValidationRejectsAmbiguousOrCredentialedURLs() throws {
    #expect(try CelestiAPIConfiguration.validatedBaseURL("http://localhost:3000") == URL(string: "http://localhost:3000"))
    #expect(throws: CelestiAPIConfigurationError.invalidDebugBaseURL) {
        try CelestiAPIConfiguration.validatedBaseURL("localhost:3000")
    }
    #expect(throws: CelestiAPIConfigurationError.invalidDebugBaseURL) {
        try CelestiAPIConfiguration.validatedBaseURL("https://user:secret@example.test")
    }
    #expect(throws: CelestiAPIConfigurationError.invalidDebugBaseURL) {
        try CelestiAPIConfiguration.validatedBaseURL("https://example.test?target=other")
    }
}

private func channelPage(ids: [String], total: Int, page: Int, limit: Int) -> String {
    let channels = ids.map { id in
        """
        {"id":"\(id)","tvgName":"\(id)","tvgLogo":null,"streamUrl":"https://media.invalid/\(id).m3u8","groupTitle":null,"medium":"automatic"}
        """
    }.joined(separator: ",")
    return """
    {"data":[\(channels)],"total":\(total),"page":\(page),"limit":\(limit)}
    """
}

private actor ScriptedChannelLibraryClient: ChannelLibraryHTTPClient {
    enum Response: Sendable {
        case json(String, status: Int = 200)
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        switch response {
        case let .json(body, status):
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
    }
}
