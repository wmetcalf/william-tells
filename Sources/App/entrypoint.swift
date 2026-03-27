import Vapor
import Foundation

@main
struct App {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        try configure(app)
        try routes(app)
        try await app.execute()
        try await app.asyncShutdown()
    }
}

func configure(_ app: Application) throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "8080") ?? 8080
    app.routes.defaultMaxBodySize = "50mb"

    let encoder = JSONEncoder()
    encoder.outputFormatting = app.environment == .development
        ? [.prettyPrinted, .sortedKeys]
        : []
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

    // Basic auth from CLI args or env vars
    let username = Environment.get("WTQRK_USER")
    let password = Environment.get("WTQRK_PASS")

    if let username, let password, !username.isEmpty, !password.isEmpty {
        let authMiddleware = BasicAuthMiddleware(username: username, password: password)
        app.middleware.use(authMiddleware)
        app.logger.info("Basic auth enabled for user: \(username)")
    } else {
        app.logger.info("No auth configured (set WTQRK_USER and WTQRK_PASS to enable)")
    }

    app.logger.info("William Tells QR Killer starting on port \(app.http.server.configuration.port)")
}

// MARK: - Basic Auth Middleware

struct BasicAuthMiddleware: AsyncMiddleware {
    let username: String
    let password: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Allow health check without auth
        if request.url.path == "/health" {
            return try await next.respond(to: request)
        }

        guard let authHeader = request.headers[.authorization].first,
              authHeader.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(authHeader.dropFirst(6))),
              let credentials = String(data: decoded, encoding: .utf8)
        else {
            return unauthorizedResponse()
        }

        let parts = credentials.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              String(parts[0]) == username,
              String(parts[1]) == password
        else {
            return unauthorizedResponse()
        }

        return try await next.respond(to: request)
    }

    private func unauthorizedResponse() -> Response {
        let response = Response(status: .unauthorized)
        response.headers.replaceOrAdd(name: .wwwAuthenticate, value: "Basic realm=\"QR Scanner\"")
        response.body = .init(string: "Unauthorized")
        return response
    }
}
