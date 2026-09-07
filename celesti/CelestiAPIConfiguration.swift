import Foundation

nonisolated enum CelestiAPIConfiguration {
    static let productionBaseURL = URL(string: "https://api.celesti.gaulatti.com")!
    static let debugBaseURLEnvironmentKey = "CELESTI_API_BASE_URL"

    static var baseURL: URL {
#if DEBUG
        guard let override = ProcessInfo.processInfo.environment[debugBaseURLEnvironmentKey] else {
            return productionBaseURL
        }
        do {
            return try validatedBaseURL(override)
        } catch {
            fatalError("Invalid \(debugBaseURLEnvironmentKey): \(error.localizedDescription)")
        }
#else
        return productionBaseURL
#endif
    }

    static func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    static func validatedBaseURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw CelestiAPIConfigurationError.invalidDebugBaseURL
        }
        return url
    }
}

enum CelestiAPIConfigurationError: LocalizedError, Equatable {
    case invalidDebugBaseURL

    var errorDescription: String? {
        "the debug API base must be an absolute HTTP(S) URL without credentials, a query, or a fragment"
    }
}
