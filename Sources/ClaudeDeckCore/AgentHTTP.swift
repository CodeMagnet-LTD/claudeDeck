import Foundation

// A tiny HTTP/1.1 reader and writer for the agents API (AgentAPIServer). One request per connection,
// Content-Length bodies only (no chunked encoding). The listener that speaks it is in the app.

public enum AgentHTTP {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 1 << 20

    public static func decode(_ buffer: Data) -> AgentHTTPDecode {
        guard let headerEnd = buffer.range(of: Data([13, 10, 13, 10])) else {
            return buffer.count > maxHeaderBytes ? .invalid : .needMore
        }
        if headerEnd.lowerBound > maxHeaderBytes { return .invalid }
        guard let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .invalid }
        let method = String(parts[0])
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return .invalid }
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pathAndQuery[0])
        let query = pathAndQuery.count > 1 ? queryItems(String(pathAndQuery[1])) : [:]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            if headers[name] != nil, name == "content-length" { return .invalid }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid }

        let bodyStart = headerEnd.upperBound
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { return .invalid }
            if parsed > maxBodyBytes { return .tooLarge }
            length = parsed
        } else {
            length = 0
        }
        guard buffer.count >= bodyStart + length else { return .needMore }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .ready(AgentHTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    public static func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        guard !query.isEmpty else { return items }
        for pair in query.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = percentDecode(String(pieces[0]))
            guard !name.isEmpty else { continue }
            let value = pieces.count > 1 ? percentDecode(String(pieces[1])) : ""
            items[name] = value
        }
        return items
    }

    public static func percentDecode(_ string: String) -> String {
        let plus = string.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }
}

public enum AgentHTTPDecode: Equatable, Sendable {
    case needMore
    case ready(AgentHTTPRequest)
    case invalid
    case tooLarge
}

public struct AgentHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct AgentHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var authenticate: Bool

    public init(status: Int, body: Data, contentType: String = "application/json; charset=utf-8", authenticate: Bool = false) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.authenticate = authenticate
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> AgentHTTPResponse {
        let data = (try? AgentJSON.encode(value)) ?? Data("{}".utf8)
        return AgentHTTPResponse(status: status, body: data, authenticate: status == 401)
    }

    public static func error(_ status: Int, _ code: String) -> AgentHTTPResponse {
        json(status, AgentErrorBody(error: code))
    }

    public func encoded() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        if authenticate { head += "WWW-Authenticate: Bearer\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

public struct AgentErrorBody: Encodable, Equatable, Sendable {
    public var error: String
    public init(error: String) { self.error = error }
}
