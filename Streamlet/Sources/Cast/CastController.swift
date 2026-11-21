import Combine
import CoreAudio
import Foundation

/// Sends the audio of Streamlet to a Google Cast device (for example a Chromecast Audio).
///
/// The audio goes this way: a Core Audio process tap records the WebKit processes of the
/// app and keeps the Mac's speakers silent. A small HTTP server sends the samples as an
/// endless WAV stream. The Default Media Receiver on the device plays this stream.
final class CastController: ObservableObject {
    static let shared = CastController()

    enum Status: Equatable {
        case idle
        case connecting(CastDevice)
        case casting(CastDevice)
        case failed(CastDevice?, String)
    }

    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var isSearching = false

    /// Process taps need macOS 14.2.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// True after the first cast. Then discovery starts with the app, so devices are ready in the menu.
    private static let usedKey = "castWasUsed"

    private let browser = CastBrowser()
    private var client: CastClient?
    private var server: AudioStreamServer?
    private var tap: AnyObject?
    private var silenceTimer: DispatchSourceTimer?
    private var lastSamples = Date.distantPast
    private let samplesLock = NSLock()
    private weak var playerState: PlayerState?
    private var trackObservation: AnyCancellable?

    /// Connects the cast device to the player: it shows the track and its controls go to the player.
    func attach(_ playerState: PlayerState) {
        self.playerState = playerState
        trackObservation = playerState.$currentTrack
            .combineLatest(playerState.$isConnectedToService)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // @Published sends before the value changes: read the state on the next turn.
                DispatchQueue.main.async { self?.updateTrack() }
            }
    }

    private var currentTrack: CastClient.Track {
        guard let playerState, playerState.hasTrack else {
            return CastClient.Track(title: "Streamlet", artist: playerState?.serviceName ?? "", album: "", imageURL: nil)
        }
        let track = playerState.currentTrack
        // The device and the Google Home app load the cover themselves: only web URLs work.
        let image = track.albumArt.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
        return CastClient.Track(title: track.title, artist: track.artist, album: track.album, imageURL: image)
    }

    private func updateTrack() {
        client?.setTrack(currentTrack)
    }

    var activeDevice: CastDevice? {
        switch status {
        case .connecting(let device), .casting(let device): return device
        default: return nil
        }
    }

    private init() {
        browser.onChange = { [weak self] devices in self?.devices = devices }
        if Self.isSupported, UserDefaults.standard.bool(forKey: Self.usedKey) {
            startDiscovery()
        }
    }

    /// Starts to look for devices. The first time, macOS asks for access to the local network.
    func startDiscovery() {
        guard Self.isSupported, !isSearching else { return }
        isSearching = true
        browser.start()
    }

    func toggle(_ device: CastDevice) {
        if activeDevice == device {
            stop()
        } else {
            cast(to: device)
        }
    }

    func cast(to device: CastDevice) {
        guard #available(macOS 14.2, *) else { return }
        stop()
        UserDefaults.standard.set(true, forKey: Self.usedKey)
        status = .connecting(device)
        // Never stay in "connecting": the device can take a while, but not this long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.status == .connecting(device) else { return }
            self.fail("The device did not start to play.")
        }

        let client = CastClient(device: device)
        self.client = client
        client.setTrack(currentTrack)
        client.onEvent = { [weak self, weak client] event in
            guard let self, let client, self.client === client else { return }
            self.handle(event, device: device)
        }
        client.connect()
    }

    func stop() {
        client?.onEvent = nil
        client?.stop()
        client = nil
        stopAudio()
        if case .failed = status { return }
        status = .idle
    }

    /// Stops casting and waits a moment, so that the STOP message reaches the device before the app quits.
    func stopAndWait() {
        guard client != nil else { return }
        stop()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func handle(_ event: CastClient.Event, device: CastDevice) {
        switch event {
        case .connected(let address):
            startAudio(address: address, device: device)
        case .playing:
            if case .connecting = status { status = .casting(device) }
        case .volume:
            break
        case .command(let command):
            switch command {
            case "playPause": playerState?.togglePlayPause()
            case "next": playerState?.next()
            case "previous": playerState?.previous()
            default: break
            }
        case .stoppedByDevice:
            stop()
        case .failed(let message):
            fail(message)
        }
    }

    // MARK: - Audio

    private func startAudio(address: String, device: CastDevice) {
        guard #available(macOS 14.2, *) else { return }
        let rate = Self.defaultOutputSampleRate() ?? 48000
        let server = AudioStreamServer()
        self.server = server

        let tap = AppAudioTap()
        self.tap = tap
        tap.onSamples = { [weak self, weak server] data in
            guard let self else { return }
            self.samplesLock.withLock { self.lastSamples = Date() }
            server?.send(data)
        }

        server.start(sampleRate: rate) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.server === server else { return }
                switch result {
                case .success(let port):
                    do {
                        try tap.start()
                    } catch {
                        self.fail("Streamlet cannot record its audio: \(error.localizedDescription)")
                        return
                    }
                    if abs(tap.sampleRate - rate) > 1 {
                        NSLog("Streamlet cast: tap rate \(tap.sampleRate) differs from stream rate \(rate)")
                    }
                    self.startSilence(rate: rate, server: server)
                    let url = URL(string: "http://\(address):\(port)\(server.path)")!
                    NSLog("Streamlet cast: streaming \(url) to \(device.name)")
                    self.client?.load(url: url)
                case .failure(let error):
                    self.fail("Cannot start the audio stream: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Sends silence while the tap gives no samples, for example before anything plays.
    /// Without data, the device stops to wait for the stream.
    private func startSilence(rate: Double, server: AudioStreamServer) {
        let interval = 0.1
        let frames = Int(rate * interval)
        let silence = Data(count: frames * 4)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self, weak server] in
            guard let self else { return }
            let last = self.samplesLock.withLock { self.lastSamples }
            if Date().timeIntervalSince(last) > interval * 2 {
                server?.send(silence)
            }
        }
        timer.resume()
        silenceTimer = timer
    }

    private func stopAudio() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if #available(macOS 14.2, *), let tap = tap as? AppAudioTap {
            tap.onSamples = nil
            tap.stop()
        }
        tap = nil
        server?.stop()
        server = nil
    }

    #if DEBUG
    /// STREAMLET_CAST_LOCAL=1 starts only the tap and the stream server (for curl).
    /// STREAMLET_CAST_TO=<part of a device name> casts to that device when it is found.
    func runDebugIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["STREAMLET_CAST_LOCAL"] == "1" {
            startAudio(address: "127.0.0.1", device: CastDevice(id: "local", name: "local", model: "", endpoint: .hostPort(host: "127.0.0.1", port: 1)))
        }
        if let name = env["STREAMLET_CAST_TO"] {
            startDiscovery()
            var done = false
            browser.onChange = { [weak self] devices in
                self?.devices = devices
                if !done, let device = devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    done = true
                    self?.cast(to: device)
                }
            }
        }
    }
    #endif

    private func fail(_ message: String) {
        NSLog("Streamlet cast: \(message)")
        let device = activeDevice
        stop()
        status = .failed(device, message)
    }

    private static func defaultOutputSampleRate() -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}
