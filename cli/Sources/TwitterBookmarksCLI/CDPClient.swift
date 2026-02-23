import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CDPClientError: LocalizedError {
    case invalidEndpoint(String)
    case notConnected
    case connectionFailed(String)
    case connectionClosed
    case timedOut(command: String, timeout: TimeInterval)
    case commandFailed(code: Int?, message: String)
    case invalidResponse(String)
    case evaluationFailed(String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Invalid CDP endpoint: \(endpoint)"
        case .notConnected:
            return "CDP client is not connected."
        case .connectionFailed(let details):
            return "Unable to connect to Chrome CDP endpoint. \(details)"
        case .connectionClosed:
            return "CDP connection was closed."
        case .timedOut(let command, let timeout):
            return "Timed out waiting for CDP command '\(command)' after \(Int(timeout))s."
        case .commandFailed(let code, let message):
            if let code {
                return "CDP command failed (code \(code)): \(message)"
            }
            return "CDP command failed: \(message)"
        case .invalidResponse(let reason):
            return "Invalid CDP response: \(reason)"
        case .evaluationFailed(let details):
            return "JavaScript evaluation failed: \(details)"
        case .transport(let error):
            return "CDP transport error: \(error.localizedDescription)"
        }
    }
}

final class CDPClient {
    private struct OperationTimeoutError: Error {}

    private let endpointURL: URL
    private let commandTimeout: TimeInterval
    private let session: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private let stateQueue = DispatchQueue(label: "twitter.bookmarks.cdp.state")
    private var nextMessageID: Int = 0
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(
        host: String = "127.0.0.1",
        port: Int,
        path: String = "/cdp",
        commandTimeout: TimeInterval = 15
    ) throws {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = path

        guard let endpointURL = components.url else {
            throw CDPClientError.invalidEndpoint("ws://\(host):\(port)\(path)")
        }

        self.endpointURL = endpointURL
        self.commandTimeout = commandTimeout
        self.session = URLSession(configuration: .default)
    }

    func connect() async throws {
        if webSocketTask != nil {
            return
        }

        let task = session.webSocketTask(with: endpointURL)
        webSocketTask = task
        task.resume()

        startReceiveLoop(task: task)

        do {
            try await ping(timeout: 5)
        } catch {
            await disconnect()
            throw CDPClientError.connectionFailed(
                "Ensure Chrome is reachable at \(endpointURL.absoluteString) and remote debugging is active."
            )
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        failAllPending(with: CDPClientError.connectionClosed)
    }

    func sendCommand(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        guard let webSocketTask else {
            throw CDPClientError.notConnected
        }

        let id = reserveMessageID()
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]

        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw CDPClientError.invalidResponse("Failed to encode request for method \(method).")
        }

        guard let jsonText = String(data: jsonData, encoding: .utf8) else {
            throw CDPClientError.invalidResponse("Failed to encode UTF-8 request for method \(method).")
        }

        let responseTask = Task<[String: Any], Error> { [weak self] in
            guard let self else {
                throw CDPClientError.connectionClosed
            }

            return try await withCheckedThrowingContinuation { continuation in
                self.registerContinuation(continuation, for: id)
            }
        }

        do {
            try await webSocketTask.send(.string(jsonText))
        } catch {
            responseTask.cancel()
            failPending(id: id, error: CDPClientError.transport(error))
            throw CDPClientError.transport(error)
        }

        do {
            return try await withTimeout(timeout ?? commandTimeout) {
                try await responseTask.value
            }
        } catch is OperationTimeoutError {
            responseTask.cancel()
            let timeoutValue = timeout ?? commandTimeout
            let timeoutError = CDPClientError.timedOut(command: method, timeout: timeoutValue)
            failPending(id: id, error: timeoutError)
            throw timeoutError
        } catch let error as CDPClientError {
            responseTask.cancel()
            failPending(id: id, error: error)
            throw error
        } catch {
            responseTask.cancel()
            let timeoutValue = timeout ?? commandTimeout
            failPending(id: id, error: CDPClientError.timedOut(command: method, timeout: timeoutValue))
            throw CDPClientError.timedOut(command: method, timeout: timeoutValue)
        }
    }

    func evaluate(
        _ expression: String,
        awaitPromise: Bool = true,
        returnByValue: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> Any? {
        let response = try await sendCommand(
            "Runtime.evaluate",
            params: [
                "expression": expression,
                "awaitPromise": awaitPromise,
                "returnByValue": returnByValue
            ],
            timeout: timeout
        )

        guard let envelope = response["result"] as? [String: Any] else {
            throw CDPClientError.invalidResponse("Missing Runtime.evaluate envelope.")
        }

        if let exceptionDetails = envelope["exceptionDetails"] as? [String: Any] {
            let text = (exceptionDetails["text"] as? String) ?? "Unknown JavaScript exception."
            throw CDPClientError.evaluationFailed(text)
        }

        guard let result = envelope["result"] as? [String: Any] else {
            throw CDPClientError.invalidResponse("Missing Runtime.evaluate result object.")
        }

        return result["value"]
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.processIncomingMessage(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.processIncomingMessage(text: text)
                        }
                    @unknown default:
                        continue
                    }
                } catch {
                    if Task.isCancelled {
                        break
                    }
                    self.failAllPending(with: CDPClientError.transport(error))
                    break
                }
            }
        }
    }

    private func processIncomingMessage(text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }

        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard let id = intValue(message["id"]) else {
            return
        }

        if
            let errorPayload = message["error"] as? [String: Any],
            let messageText = errorPayload["message"] as? String
        {
            failPending(
                id: id,
                error: CDPClientError.commandFailed(
                    code: intValue(errorPayload["code"]),
                    message: messageText
                )
            )
            return
        }

        resolvePending(id: id, response: message)
    }

    private func ping(timeout: TimeInterval) async throws {
        guard let webSocketTask else {
            throw CDPClientError.notConnected
        }

        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                webSocketTask.sendPing { error in
                    if let error {
                        continuation.resume(throwing: CDPClientError.transport(error))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    private func reserveMessageID() -> Int {
        stateQueue.sync {
            nextMessageID += 1
            return nextMessageID
        }
    }

    private func registerContinuation(
        _ continuation: CheckedContinuation<[String: Any], Error>,
        for id: Int
    ) {
        stateQueue.sync {
            pendingResponses[id] = continuation
        }
    }

    private func resolvePending(id: Int, response: [String: Any]) {
        let continuation: CheckedContinuation<[String: Any], Error>? = stateQueue.sync {
            pendingResponses.removeValue(forKey: id)
        }
        continuation?.resume(returning: response)
    }

    private func failPending(id: Int, error: Error) {
        let continuation: CheckedContinuation<[String: Any], Error>? = stateQueue.sync {
            pendingResponses.removeValue(forKey: id)
        }
        continuation?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let continuations: [CheckedContinuation<[String: Any], Error>] = stateQueue.sync {
            let values = Array(pendingResponses.values)
            pendingResponses.removeAll()
            return values
        }
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func withTimeout<T>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OperationTimeoutError()
            }

            guard let result = try await group.next() else {
                throw CDPClientError.connectionClosed
            }

            group.cancelAll()
            return result
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
