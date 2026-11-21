import Foundation
import Network

/// A Google Cast device found on the local network.
struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let endpoint: NWEndpoint

    static func == (a: CastDevice, b: CastDevice) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds Google Cast devices with Bonjour.
final class CastBrowser {
    var onChange: (([CastDevice]) -> Void)?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap(Self.device).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.onChange?(devices) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("Streamlet cast: discovery failed: \(error)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func device(_ result: NWBrowser.Result) -> CastDevice? {
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        var serviceName = ""
        if case .service(let name, _, _, _) = result.endpoint { serviceName = name }
        let id = txt["id"] ?? serviceName
        let name = txt["fn"] ?? serviceName
        return CastDevice(id: id, name: name, model: txt["md"] ?? "", endpoint: result.endpoint)
    }
}

/// Speaks the Cast V2 protocol with one device: it starts the Default Media Receiver and
/// lets it play a URL. Only the small part of the protocol that Streamlet needs.
final class CastClient {
    enum Event {
        case connected(localAddress: String)
        case playing
        case volume(Double, muted: Bool)
        /// The receiver app was closed, for example by another sender.
        case stoppedByDevice
        case failed(String)
        /// A control on the device or in the Google Home app: "playPause", "next" or "previous".
        case command(String)
    }

    /// The track that the receiver shows.
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var imageURL: URL?
    }

    var onEvent: ((Event) -> Void)?

    /// Streamlet's own receiver (docs/receiver). It can show the current track without
    /// loading the stream again.
    private static let streamletReceiver = "E314E16E"
    /// Google's receiver. Used when Streamlet's receiver does not start.
    private static let defaultMediaReceiver = "CC1AD845"
    private static let nsStreamlet = "urn:x-cast:com.fgnass.streamlet"
    private static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private static let nsMedia = "urn:x-cast:com.google.cast.media"
    private static let senderID = "sender-streamlet"

    private let queue = DispatchQueue(label: "streamlet.cast.client")
    private let connection: NWConnection
    private var buffer = Data()
    private var requestID = 0
    private var heartbeat: DispatchSourceTimer?
    private var transportID: String?
    private var sessionID: String?
    /// The request ID of our LOAD message, and the media session that the device made for it.
    private var loadRequestID: Int?
    private var mediaSessionID: Int?
    private var appID = CastClient.streamletReceiver
    private var pendingURL: URL?
    private var loadedURL: URL?
    private var track = Track(title: "Streamlet", artist: "", album: "", imageURL: nil)
    private var isClosed = false

    init(device: CastDevice) {
        let tls = NWProtocolTLS.Options()
        // Cast devices use self-signed certificates.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let parameters = NWParameters(tls: tls, tcp: .init())
        // The address family must match the address that the device can reach later (IPv4).
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        connection = NWConnection(to: device.endpoint, using: parameters)
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(Self.nsConnection, to: "receiver-0", ["type": "CONNECT"])
                self.startHeartbeat()
                self.receive()
                let address = self.localAddress() ?? ""
                self.emit(.connected(localAddress: address))
                self.send(Self.nsReceiver, to: "receiver-0", ["type": "GET_STATUS"])
            case .failed(let error):
                self.fail("Connection failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.fail("Cannot reach the device: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Starts the receiver app and loads the URL as a live audio stream.
    func load(url: URL) {
        queue.async { [self] in
            pendingURL = url
            if transportID != nil {
                sendLoad()
            } else {
                send(Self.nsReceiver, to: "receiver-0", ["type": "LAUNCH", "appId": appID])
            }
        }
    }

    /// Shows a new track on the device. Only Streamlet's receiver can do this while the stream plays.
    func setTrack(_ track: Track) {
        queue.async { [self] in
            guard track != self.track else { return }
            self.track = track
            guard appID == Self.streamletReceiver, let transportID, mediaSessionID != nil else { return }
            sendTrack(to: transportID)
        }
    }

    private func sendTrack(to transportID: String) {
        var message: [String: Any] = [
            "type": "track",
            "title": track.title,
            "artist": track.artist,
            "album": track.album,
        ]
        if let image = track.imageURL { message["image"] = image.absoluteString }
        send(Self.nsStreamlet, to: transportID, message)
    }

    func setVolume(_ level: Double) {
        queue.async { [self] in
            send(Self.nsReceiver, to: "receiver-0", ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))]])
        }
    }

    /// Closes the receiver app on the device and the connection.
    func stop() {
        queue.async { [self] in
            if let sessionID {
                send(Self.nsReceiver, to: "receiver-0", ["type": "STOP", "sessionId": sessionID])
            }
            // Give the device a moment to get the message before the connection closes.
            queue.asyncAfter(deadline: .now() + 0.3) { self.close() }
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
    }

    private func fail(_ message: String) {
        guard !isClosed else { return }
        close()
        emit(.failed(message))
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    private func localAddress() -> String? {
        guard case .hostPort(let host, _) = connection.currentPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first
        case .ipv6(let address):
            return "[\(address)]"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.send(Self.nsHeartbeat, to: "receiver-0", ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - Messages

    private func sendLoad() {
        guard let url = pendingURL, let transportID else { return }
        pendingURL = nil
        loadedURL = url
        var metadata: [String: Any] = [
            "metadataType": 3,  // MusicTrackMediaMetadata
            "title": track.title,
            "artist": track.artist,
            "albumName": track.album,
        ]
        if let image = track.imageURL {
            metadata["images"] = [["url": image.absoluteString]]
        }
        mediaSessionID = nil
        loadRequestID = send(Self.nsMedia, to: transportID, [
            "type": "LOAD",
            "autoplay": true,
            "currentTime": 0,
            "media": [
                "contentId": url.absoluteString,
                "contentUrl": url.absoluteString,
                "contentType": "audio/wav",
                "streamType": "LIVE",
                "metadata": metadata,
            ],
        ])
    }

    private func handle(namespace: String, source: String, payload: String) {
        #if DEBUG
        if !namespace.hasSuffix("heartbeat") { NSLog("cast <- \(source) \(namespace) \(payload.prefix(600))") }
        #endif
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch (namespace, type) {
        case (Self.nsHeartbeat, "PING"):
            send(Self.nsHeartbeat, to: source, ["type": "PONG"])
        case (Self.nsConnection, "CLOSE"):
            if source == transportID {
                transportID = nil
                sessionID = nil
                emit(.stoppedByDevice)
            }
        case (Self.nsReceiver, "RECEIVER_STATUS"):
            handleReceiverStatus(json["status"] as? [String: Any] ?? [:])
        case (Self.nsReceiver, "LAUNCH_ERROR"):
            if appID == Self.streamletReceiver {
                // For example when the receiver page is not reachable. Google's receiver
                // plays the stream too, but shows only "Streamlet" as the track.
                NSLog("Streamlet cast: Streamlet's receiver did not start, using the Default Media Receiver")
                appID = Self.defaultMediaReceiver
                send(Self.nsReceiver, to: "receiver-0", ["type": "LAUNCH", "appId": appID])
            } else {
                fail("The device cannot start the media player.")
            }
        case (Self.nsStreamlet, "buffer"):
            // The receiver reports its buffer every second. Logged only in debug builds.
            break
        case (Self.nsStreamlet, "command"):
            if let command = json["command"] as? String { emit(.command(command)) }
        case (Self.nsMedia, "LOAD_FAILED"), (Self.nsMedia, "LOAD_CANCELLED"), (Self.nsMedia, "INVALID_REQUEST"):
            // Only errors for our own LOAD count.
            if let id = json["requestId"] as? Int, id == loadRequestID {
                fail("The device rejected the stream (\(type)).")
            }
        case (Self.nsMedia, "MEDIA_STATUS"):
            let statuses = json["status"] as? [[String: Any]] ?? []
            // Find our media session: its media has our stream URL. (The Default Media Receiver
            // answers a LOAD with requestId 0, so the request ID does not help.) Ignore the
            // status of older sessions.
            if mediaSessionID == nil, let loadedURL,
               let status = statuses.first(where: { Self.contentURL(of: $0) == loadedURL.absoluteString }) {
                mediaSessionID = status["mediaSessionId"] as? Int
                // The track can change between LOAD and its answer.
                if mediaSessionID != nil, appID == Self.streamletReceiver { sendTrack(to: source) }
            }
            guard let status = statuses.first, let mediaSessionID,
                  status["mediaSessionId"] as? Int == mediaSessionID
            else { return }
            if let state = status["playerState"] as? String, state == "PLAYING" || state == "BUFFERING" {
                emit(.playing)
            }
            if let idle = status["idleReason"] as? String, idle == "ERROR" {
                fail("The device could not play the stream.")
            }
        default:
            break
        }
    }

    private static func contentURL(of status: [String: Any]) -> String? {
        guard let media = status["media"] as? [String: Any] else { return nil }
        return (media["contentUrl"] as? String) ?? (media["contentId"] as? String)
    }

    private func handleReceiverStatus(_ status: [String: Any]) {
        if let volume = status["volume"] as? [String: Any], let level = volume["level"] as? Double {
            emit(.volume(level, muted: volume["muted"] as? Bool ?? false))
        }
        let apps = status["applications"] as? [[String: Any]] ?? []
        let app = apps.first { $0["appId"] as? String == appID }
        if let app, let transport = app["transportId"] as? String {
            sessionID = app["sessionId"] as? String
            if transportID != transport {
                transportID = transport
                send(Self.nsConnection, to: transport, ["type": "CONNECT"])
            }
            sendLoad()
        } else if transportID != nil {
            // Our receiver app is gone, for example because another app was cast.
            transportID = nil
            sessionID = nil
            emit(.stoppedByDevice)
        }
    }

    @discardableResult
    private func send(_ namespace: String, to destination: String, _ message: [String: Any]) -> Int {
        var message = message
        if message["type"] as? String != "PING", message["type"] as? String != "PONG" {
            requestID += 1
            message["requestId"] = requestID
        }
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let payload = String(data: json, encoding: .utf8)
        else { return requestID }
        #if DEBUG
        if !namespace.hasSuffix("heartbeat") { NSLog("cast -> \(destination) \(namespace) \(payload)") }
        #endif
        let body = CastMessage(source: Self.senderID, destination: destination, namespace: namespace, payload: payload).encoded()
        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("Sending failed: \(error.localizedDescription)") }
        })
        return requestID
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                self.processBuffer()
            }
            if let error {
                self.fail("Connection lost: \(error.localizedDescription)")
            } else if isComplete {
                self.fail("The device closed the connection.")
            } else {
                self.receive()
            }
        }
    }

    private func processBuffer() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
            buffer.removeFirst(4 + length)
            if let message = CastMessage(decoding: body), let payload = message.payload {
                handle(namespace: message.namespace, source: message.source, payload: payload)
            }
        }
    }
}

/// The protobuf message of the Cast V2 protocol (cast_channel.proto), encoded by hand.
struct CastMessage {
    var source: String
    var destination: String
    var namespace: String
    var payload: String?

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data()
        func varint(_ value: Int) {
            var v = UInt64(value)
            repeat {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                data.append(byte)
            } while v != 0
        }
        func field(_ number: Int, _ string: String) {
            let bytes = Data(string.utf8)
            varint(number << 3 | 2)
            varint(bytes.count)
            data.append(bytes)
        }
        varint(1 << 3); varint(0)  // protocol_version = CASTV2_1_0
        field(2, source)
        field(3, destination)
        field(4, namespace)
        varint(5 << 3); varint(0)  // payload_type = STRING
        field(6, payload ?? "")
        return data
    }

    init?(decoding data: Data) {
        var source = "", destination = "", namespace = ""
        var payload: String?
        var index = data.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while index < data.endIndex {
            guard let key = varint() else { return nil }
            let number = key >> 3
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let length = varint(), index + Int(length) <= data.endIndex else { return nil }
                let bytes = data[index..<index + Int(length)]
                index += Int(length)
                let string = String(decoding: bytes, as: UTF8.self)
                switch number {
                case 2: source = string
                case 3: destination = string
                case 4: namespace = string
                case 6: payload = string
                default: break
                }
            default:
                return nil
            }
        }
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }
}
