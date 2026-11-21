import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Records the audio output of Streamlet and of the WebKit processes that play for it,
/// with a Core Audio process tap. While the tap runs, the Mac's speakers stay silent.
///
/// WebKit plays media in helper processes (GPU and WebContent). They are not children of the
/// app, but the app is their "responsible" process. The tap includes every audio process
/// whose responsible process is this app. New helper processes start to play later, so the
/// tap is created again when the list of audio processes changes.
@available(macOS 14.2, *)
final class AppAudioTap {
    /// Gets interleaved 16-bit stereo samples. Called on a real-time audio queue.
    var onSamples: ((Data) -> Void)?
    /// The sample rate of the samples that `onSamples` gets.
    private(set) var sampleRate: Double = 48000

    private let queue = DispatchQueue(label: "streamlet.cast.tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var isRunning = false

    enum TapError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let status): return "\(what) failed (\(status))"
            }
        }
    }

    /// Starts to record. Calls `onSamples` as soon as the app plays audio.
    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        try rebuildIfNeeded()
        listenForProcessChanges()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let listener = processListListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            processListListener = nil
        }
        teardown()
        tappedProcesses = []
    }

    deinit { stop() }

    // MARK: - Processes

    private func listenForProcessChanges() {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            do {
                try self.rebuildIfNeeded()
            } catch {
                NSLog("Streamlet cast: cannot update the audio tap: \(error.localizedDescription)")
            }
        }
        processListListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }

    /// The audio process objects of this app and of its WebKit helpers.
    private func ownAudioProcesses() -> [AudioObjectID] {
        let ownPID = getpid()
        // Usually the app is responsible for itself. When a terminal starts the app, the
        // terminal is responsible for the app and for its WebKit helpers.
        let ownResponsible = Self.responsiblePID(for: ownPID) ?? ownPID
        let all: [AudioObjectID] = (try? Self.readArray(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)) ?? []
        return all.filter { process in
            guard let pid: pid_t = try? Self.read(process, kAudioProcessPropertyPID) else { return false }
            if pid == ownPID { return true }
            guard let responsible = Self.responsiblePID(for: pid) else { return false }
            if responsible == ownPID { return true }
            return responsible == ownResponsible && Self.bundleID(of: process)?.hasPrefix("com.apple.WebKit") == true
        }.sorted()
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        guard let value: CFString = try? read(process, kAudioProcessPropertyBundleID) else { return nil }
        return value as String
    }

    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        responsibleFunction?(pid)
    }

    // MARK: - Tap

    private func rebuildIfNeeded() throws {
        let processes = ownAudioProcesses()
        guard processes != tappedProcesses else { return }
        teardown()
        tappedProcesses = processes
        // Nothing has played yet. The listener creates the tap when a process starts.
        guard !processes.isEmpty else { return }
        try build(processes: processes)
    }

    private func build(processes: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Streamlet Cast"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap")
        tapID = tap

        let format: AudioStreamBasicDescription = try Self.read(tap, kAudioTapPropertyFormat)
        sampleRate = format.mSampleRate

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Streamlet Cast",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Creating the aggregate device")
        aggregateID = device

        let channels = Int(format.mChannelsPerFrame)
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard isFloat, format.mBitsPerChannel == 32 else {
            throw TapError.coreAudio("Unexpected tap format", OSStatus(format.mFormatFlags))
        }
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in
            guard let self, let onSamples = self.onSamples else { return }
            let data = Self.convertToInt16Stereo(input, channels: channels, nonInterleaved: isNonInterleaved)
            if !data.isEmpty { onSamples(data) }
        }, "Creating the audio callback")
        ioProcID = procID
        try check(AudioDeviceStart(device, procID), "Starting the audio tap")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Makes interleaved little-endian 16-bit stereo from the 32-bit float buffers of the tap.
    private static func convertToInt16Stereo(
        _ list: UnsafePointer<AudioBufferList>, channels: Int, nonInterleaved: Bool
    ) -> Data {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let firstData = first.mData else { return Data() }

        @inline(__always) func sample(_ value: Float) -> Int16 {
            Int16(max(-1, min(1, value)) * 32767)
        }

        if nonInterleaved {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let left = firstData.assumingMemoryBound(to: Float.self)
            let right = (buffers.count > 1 ? buffers[1].mData : firstData)!.assumingMemoryBound(to: Float.self)
            var out = [Int16](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                out[2 * i] = sample(left[i])
                out[2 * i + 1] = sample(right[i])
            }
            return out.withUnsafeBytes { Data($0) }
        } else {
            let stride = max(channels, 1)
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
            let input = firstData.assumingMemoryBound(to: Float.self)
            var out = [Int16](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                out[2 * i] = sample(input[i * stride])
                out[2 * i + 1] = sample(input[i * stride + (stride > 1 ? 1 : 0)])
            }
            return out.withUnsafeBytes { Data($0) }
        }
    }

    // MARK: - Core Audio helpers

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.coreAudio(what, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        guard status == noErr else { throw TapError.coreAudio("Reading a property", status) }
        return pointer.load(as: T.self)
    }

    private static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw TapError.coreAudio("Reading a property size", status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            guard status == noErr else { throw TapError.coreAudio("Reading a property", status) }
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }
}
