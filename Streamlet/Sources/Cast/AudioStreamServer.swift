import Foundation
import Network

/// A small HTTP server that sends the recorded audio as an endless WAV stream.
/// The Chromecast loads this stream like a web radio.
final class AudioStreamServer {
    private let queue = DispatchQueue(label: "streamlet.cast.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var sampleRate: Double = 48000
    /// The path of the stream. It changes for each session, so that only the cast device finds it.
    private(set) var path = "/stream.wav"

    var port: UInt16? { listener?.port?.rawValue }

    func start(sampleRate: Double, completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async { [self] in
            self.sampleRate = sampleRate
            path = "/\(UUID().uuidString.lowercased()).wav"
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        completion(.success(listener.port?.rawValue ?? 0))
                    case .failed(let error):
                        completion(.failure(error))
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.cancel() }
            clients = [:]
        }
    }

    func updateSampleRate(_ rate: Double) {
        queue.async { self.sampleRate = rate }
    }

    /// Sends PCM data to all connected clients.
    func send(_ data: Data) {
        queue.async { [self] in
            for client in clients.values {
                client.send(content: data, completion: .idempotent)
            }
        }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.clients[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(connection, head: head)
            } else if error != nil || isComplete || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        #if DEBUG
        NSLog("stream request: \(head.replacingOccurrences(of: "\r\n", with: " | "))")
        #endif
        let requestLine = head.split(separator: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[1] == path else {
            send(connection, status: "404 Not Found", headers: [:], body: Data(), close: true)
            return
        }
        let method = parts[0]
        let headers = [
            "Content-Type": "audio/wav",
            "Cache-Control": "no-cache, no-store",
            "Access-Control-Allow-Origin": "*",
            "Connection": "close",
        ]
        if method == "HEAD" {
            send(connection, status: "200 OK", headers: headers, body: Data(), close: true)
            return
        }
        send(connection, status: "200 OK", headers: headers, body: wavHeader(), close: false)
        clients[ObjectIdentifier(connection)] = connection
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data, close: Bool) {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    /// A WAV header for 16-bit stereo PCM with the largest possible length, for an endless stream.
    private func wavHeader() -> Data {
        let rate = UInt32(sampleRate)
        let channels: UInt16 = 2
        let bits: UInt16 = 16
        let blockAlign = channels * bits / 8
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32.max)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(rate)
        append(rate * UInt32(blockAlign))
        append(blockAlign)
        append(bits)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32.max - 36)
        return data
    }
}
