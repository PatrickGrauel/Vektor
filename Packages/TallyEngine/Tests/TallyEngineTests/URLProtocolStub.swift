import Foundation

/// Test-only URLProtocol that intercepts every URLSession request and
/// returns a programmable response. Drives the FX / Metar / Crypto
/// failure-path tests without hitting the real network.
///
/// Usage:
///
/// ```swift
/// URLProtocolStub.responses = [
///     .init(statusCode: 500, body: Data()),                       // 1st call: server error
///     .init(statusCode: 500, body: Data()),                       // 2nd call: retry → server error
///     .init(statusCode: 200, body: try JSONEncoder().encode(...)) // 3rd call: retry → success
/// ]
/// let cfg = URLSessionConfiguration.ephemeral
/// cfg.protocolClasses = [URLProtocolStub.self]
/// let session = URLSession(configuration: cfg)
/// // pass `session` to FXService(session:) etc.
/// ```
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let body: Data
        let error: Error?
        let headers: [String: String]
        init(statusCode: Int = 200, body: Data = Data(), error: Error? = nil, headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.error = error
            self.headers = headers
        }
    }

    /// Queue of stubbed responses. Each `startLoading` call pops the head.
    /// If empty, requests return a 599 placeholder so tests fail loudly
    /// rather than waiting on a real network.
    nonisolated(unsafe) static var responses: [StubResponse] = []

    /// Records every URL the stub served, in order.
    nonisolated(unsafe) static var requests: [URL] = []

    static func reset() {
        responses.removeAll()
        requests.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requests.append(url)
        let stub = Self.responses.isEmpty
            ? StubResponse(statusCode: 599, body: Data())
            : Self.responses.removeFirst()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) ?? HTTPURLResponse()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLProtocolStub {
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolStub.self]
        cfg.timeoutIntervalForRequest = 2     // keep tests snappy on timeout cases
        return URLSession(configuration: cfg)
    }
}
