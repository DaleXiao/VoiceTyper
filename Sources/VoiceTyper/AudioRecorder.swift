import AVFoundation
import CoreGraphics
import Foundation

final class AudioRecorder {
    private enum Streaming {
        static let tapBufferSize: AVAudioFrameCount = 2_048
        static let levelUpdateInterval: TimeInterval = 1.0 / 12.0
    }

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var streamingOutputBuffer: AVAudioPCMBuffer?
    private var onPCMData: ((Data) -> Void)?
    private var streamingLevel: CGFloat = 0
    private var lastStreamingLevelUpdate: TimeInterval = 0
    private let streamQueue = DispatchQueue(label: "VoiceTyper.AudioRecorder.stream")

    var isRecording: Bool {
        recorder?.isRecording == true || audioEngine?.isRunning == true
    }

    func start() throws {
        if recorder?.isRecording == true {
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetyper-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw RecorderError.couldNotStart
        }

        self.recorder = recorder
        currentURL = url
    }

    func startStreaming(onPCMData: @escaping (Data) -> Void) throws {
        if isRecording {
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.couldNotStart
        }

        self.audioEngine = engine
        self.audioConverter = converter
        self.onPCMData = onPCMData
        streamingLevel = 0
        lastStreamingLevelUpdate = 0

        inputNode.installTap(onBus: 0, bufferSize: Streaming.tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer, inputFormat: inputFormat, outputFormat: outputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioConverter = nil
            streamingOutputBuffer = nil
            self.onPCMData = nil
            throw error
        }
    }

    func stop() throws -> URL {
        guard let recorder, let currentURL else {
            throw RecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        return currentURL
    }

    func stopStreaming() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        streamQueue.sync {}
        audioEngine = nil
        audioConverter = nil
        streamingOutputBuffer = nil
        onPCMData = nil
        streamingLevel = 0
        lastStreamingLevelUpdate = 0
    }

    func currentLevel() -> CGFloat {
        if let recorder, recorder.isRecording {
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            guard power.isFinite else {
                return 0
            }

            return Self.normalizedLevel(decibels: Double(power))
        }

        return streamingLevel
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        currentURL = nil
        stopStreaming()
    }

    private func convertAndSend(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        guard let bufferCopy = Self.copyBuffer(buffer) else {
            return
        }

        streamQueue.async { [weak self] in
            guard let self, let converter = self.audioConverter else {
                return
            }

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            let outputBuffer: AVAudioPCMBuffer
            if let reusableBuffer = self.streamingOutputBuffer,
               reusableBuffer.frameCapacity >= capacity {
                reusableBuffer.frameLength = 0
                outputBuffer = reusableBuffer
            } else {
                guard let newBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                    return
                }
                self.streamingOutputBuffer = newBuffer
                outputBuffer = newBuffer
            }

            var didProvideInput = false
            var conversionError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return bufferCopy
            }

            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
            guard status != .error, outputBuffer.frameLength > 0 else {
                return
            }

            let data = Self.pcmData(from: outputBuffer)
            guard !data.isEmpty else {
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastStreamingLevelUpdate >= Streaming.levelUpdateInterval {
                self.lastStreamingLevelUpdate = now
                let level = Self.level(fromPCMData: data)
                DispatchQueue.main.async { [weak self] in
                    self?.streamingLevel = level
                }
            }
            self.onPCMData?(data)
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                continue
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return Data()
        }

        return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    }

    private static func level(fromPCMData data: Data) -> CGFloat {
        let rms = data.withUnsafeBytes { rawBuffer -> Double in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else {
                return 0
            }

            let sum = samples.reduce(0.0) { partialResult, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partialResult + normalized * normalized
            }
            return sqrt(sum / Double(samples.count))
        }

        guard rms > 0 else {
            return 0
        }

        return normalizedLevel(decibels: 20 * log10(rms))
    }

    private static func normalizedLevel(decibels: Double) -> CGFloat {
        let clamped = max(-55, min(0, decibels))
        return CGFloat((clamped + 55) / 55)
    }
}

enum RecorderError: LocalizedError {
    case couldNotStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "录音器没有成功启动。"
        case .notRecording:
            return "当前没有正在进行的录音。"
        }
    }
}
