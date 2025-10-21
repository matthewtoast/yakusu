import AVFoundation
import AVFAudio
import Combine
import Foundation
import Speech

enum SpeechCaptureStopReason: Hashable {
    case user
    case maxDuration
    case autoStop
    case error
    case external
}

enum SpeechCaptureEvent: Hashable {
    case started
    case stopped
    case segmentRestarted
    case transcriptUpdated
    case stopRequest
}

struct SpeechCaptureConfig {
    let lineGapMs: Int
    let maxDurationMs: Int
    let segmentDurationMs: Int
    let segmentCharacterLimit: Int
    let autoStopAfterMs: Int

    static let `default` = SpeechCaptureConfig(
        lineGapMs: 3000,
        maxDurationMs: 600000,
        segmentDurationMs: 120000,
        segmentCharacterLimit: 4000,
        autoStopAfterMs: 0
    )
}

struct SpeechCaptureLine: Identifiable, Equatable {
    let id: UUID
    var text: String
    var updatedAt: Date
    var confidence: Double
    var isFinal: Bool
}

private struct TranscriptAssemblerResult: Equatable {
    let final: String?
    let live: String
    let changed: Bool
}

private struct TranscriptAssembler {
    var raw = ""
    var stable = 0
    var live = ""
    var lastChange: Date?

    mutating func reset(with text: String) {
        raw = text
        stable = text.count
        live = ""
        lastChange = nil
    }

    mutating func update(_ text: String, isFinal: Bool, timestamp: Date, gapMs: Int) -> TranscriptAssemblerResult {
        let value = text
        if stable > value.count {
            stable = value.count
        }
        let start = value.index(value.startIndex, offsetBy: stable)
        let suffix = String(value[start...])
        var changed = false
        if suffix != live {
            live = suffix
            lastChange = timestamp
            changed = true
        }
        raw = value
        var final: String?
        let idle: Double
        if let last = lastChange {
            idle = timestamp.timeIntervalSince(last) * 1000
        } else {
            idle = 0
        }
        if isFinal && !live.isEmpty {
            final = live
            stable = value.count
            live = ""
            lastChange = timestamp
            changed = true
        } else if gapMs > 0, !changed, idle >= Double(gapMs), !live.isEmpty {
            final = live
            stable = value.count
            live = ""
            lastChange = timestamp
            changed = true
        }
        return TranscriptAssemblerResult(final: final, live: live, changed: changed)
    }
}

private struct TranscriptStore {
    private(set) var lines: [SpeechCaptureLine] = []

    var text: String {
        lines.map { $0.text }.joined(separator: "\n")
    }

    mutating func reset(keep: Bool) {
        if keep {
            lines = lines.map { line in
                var item = line
                item.isFinal = true
                return item
            }
        } else {
            lines = []
        }
    }

    mutating func setLive(_ text: String, confidence: Double, date: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeLive()
            return
        }
        if let idx = lines.lastIndex(where: { !$0.isFinal }) {
            var line = lines[idx]
            line.text = trimmed
            line.updatedAt = date
            if confidence >= 0 {
                line.confidence = confidence
            }
            lines[idx] = line
        } else {
            let line = SpeechCaptureLine(id: UUID(), text: trimmed, updatedAt: date, confidence: confidence, isFinal: false)
            lines.append(line)
        }
    }

    mutating func finalizeLive(_ text: String, confidence: Double, date: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeLive()
            return
        }
        if let idx = lines.lastIndex(where: { !$0.isFinal }) {
            var line = lines[idx]
            line.text = trimmed
            line.updatedAt = date
            if confidence >= 0 {
                line.confidence = confidence
            }
            line.isFinal = true
            lines[idx] = line
        } else {
            let value = confidence >= 0 ? confidence : -1
            let line = SpeechCaptureLine(id: UUID(), text: trimmed, updatedAt: date, confidence: value, isFinal: true)
            lines.append(line)
        }
    }

    mutating func removeLive() {
        if let idx = lines.lastIndex(where: { !$0.isFinal }) {
            lines.remove(at: idx)
        }
    }
}

final class SpeechCaptureEmitter: EventEmitter<SpeechCaptureEvent> {}

@MainActor

final class SpeechCaptureController: ObservableObject {
    @Published private(set) var lines: [SpeechCaptureLine] = []
    @Published private(set) var isRecording = false

    let emitter = SpeechCaptureEmitter()

    var accumulatedText: String {
        store.text
    }

    var stopReason: SpeechCaptureStopReason? {
        lastStopReason
    }

    var stopWord: String? {
        lastStopWord
    }

    private var locale: LangLocale
    private var config: SpeechCaptureConfig
    private let recognizer: SpeechRecognizer
    private let audioSession = AVAudioSession.sharedInstance()
    private var recognitionId: UUID?
    private var segmentStart: Date?
    private var lastStopReason: SpeechCaptureStopReason?
    private var lastStopWord: String?
    private var maxDurationTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var segmentTimerTask: Task<Void, Never>?
    private var segmentBaselineLength = 0
    private var assembler = TranscriptAssembler()
    private var store = TranscriptStore()

    private lazy var handler: SpeechRecognizer.SpeechRecognitionCallback = { [weak self] transcripts, isFinal, _, confidence in
        Task { @MainActor in
            self?.handle(transcripts: transcripts, isFinal: isFinal, confidence: confidence)
        }
    }

    init(locale: LangLocale, config: SpeechCaptureConfig, recognizer: SpeechRecognizer? = nil) {
        self.locale = locale
        self.config = config
        self.recognizer = recognizer ?? SpeechRecognizer()
        emitter.on(.stopRequest) { [weak self] in
            Task { @MainActor [weak self] in
                self?.stop(reason: .external)
            }
        }
    }

    func setLocale(_ locale: LangLocale) {
        if locale == self.locale {
            return
        }
        self.locale = locale
        stop(reason: .external)
    }

    func updateConfig(_ config: SpeechCaptureConfig) {
        self.config = config
        if isRecording {
            cancelTasks()
            segmentBaselineLength = totalCharacterCount()
            scheduleMaxDuration()
            scheduleAutoStop()
            scheduleSegmentTimer()
        }
    }

    func start() async {
        if isRecording {
            return
        }
        cancelTasks()
        guard await ensurePermissions() else {
            recordFailure()
            return
        }
        clearState(keepLines: false)
        do {
            try configureSession()
            try recognizer.startStream()
            try startSegment()
            isRecording = true
            emitter.emit(.started)
            scheduleMaxDuration()
            scheduleAutoStop()
        } catch {
            cleanupAfterFailure()
            recordFailure()
        }
    }

    func stop(reason: SpeechCaptureStopReason = .user, sourceWord: String? = nil) {
        if !isRecording {
            lastStopReason = reason
            lastStopWord = sourceWord
            return
        }
        cancelTasks()
        if let id = recognitionId {
            recognizer.stopContinuous(id)
        }
        recognizer.stopStream()
        isRecording = false
        lastStopReason = reason
        lastStopWord = sourceWord
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        clearState(keepLines: true)
        emitTranscript()
        emitter.emit(.stopped)
    }

    func toggle() {
        if isRecording {
            stop(reason: .user)
        } else {
            Task {
                await start()
            }
        }
    }

    func preparePermissions() async {
        _ = await ensurePermissions()
    }

    func restartSegment() {
        guard isRecording else {
            return
        }
        if let id = recognitionId {
            recognizer.stopContinuous(id)
        }
        do {
            try startSegment()
            emitter.emit(.segmentRestarted)
        } catch {
            stop(reason: .error)
        }
    }

    private func clearState(keepLines: Bool) {
        let base = keepLines ? store.text : ""
        store.reset(keep: keepLines)
        assembler.reset(with: base)
        syncLines()
        if !keepLines {
            lastStopReason = nil
            lastStopWord = nil
        }
        recognitionId = nil
        segmentStart = nil
        segmentBaselineLength = totalCharacterCount()
    }

    private func ensurePermissions() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let audioGranted = await withCheckedContinuation { continuation in
            if #available(iOS 17, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                audioSession.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        return speechGranted && audioGranted
    }

    private func configureSession() throws {
        let options: AVAudioSession.CategoryOptions = [
            .allowBluetoothA2DP,
            .allowAirPlay,
            .duckOthers,
            .mixWithOthers,
            .defaultToSpeaker,
        ]
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
        try audioSession.setActive(true)
    }

    private func startSegment() throws {
        segmentStart = Date()
        segmentBaselineLength = totalCharacterCount()
        recognitionId = try recognizer.startContinuous(locale, callback: handler)
        scheduleSegmentTimer()
    }

    private func handle(transcripts: [String], isFinal: Bool, confidence: Double) {
        guard isRecording, let best = transcripts.first else {
            return
        }
        let now = Date()
        let result = assembler.update(best, isFinal: isFinal, timestamp: now, gapMs: config.lineGapMs)
        var changed = false
        if let final = result.final {
            store.finalizeLive(final, confidence: confidence, date: now)
            changed = true
        }
        store.setLive(result.live, confidence: confidence, date: now)
        if lines != store.lines {
            syncLines()
            changed = true
        }
        if changed || result.changed {
            emitTranscript()
        }
        if exceededSegmentLimit(now: now) {
            restartSegment()
        }
        if isFinal {
            stop(reason: .autoStop)
        }
    }

    private func syncLines() {
        lines = store.lines
    }

    private func scheduleMaxDuration() {
        schedule(task: &maxDurationTask, delayMs: config.maxDurationMs) { controller in
            controller.stop(reason: .maxDuration)
        }
    }

    private func scheduleAutoStop() {
        schedule(task: &autoStopTask, delayMs: config.autoStopAfterMs) { controller in
            controller.stop(reason: .autoStop)
        }
    }

    private func scheduleSegmentTimer() {
        schedule(task: &segmentTimerTask, delayMs: config.segmentDurationMs) { controller in
            controller.restartSegment()
        }
    }

    private func schedule(
        task: inout Task<Void, Never>?,
        delayMs: Int,
        action: @escaping (SpeechCaptureController) -> Void
    ) {
        task?.cancel()
        guard delayMs > 0 else {
            task = nil
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self, self.isRecording else {
                    return
                }
                action(self)
            }
        }
    }

    private func cancelTasks() {
        maxDurationTask?.cancel()
        autoStopTask?.cancel()
        segmentTimerTask?.cancel()
        maxDurationTask = nil
        autoStopTask = nil
        segmentTimerTask = nil
    }

    private func totalCharacterCount() -> Int {
        store.lines.reduce(into: 0) { $0 += $1.text.count }
    }

    private func exceededSegmentLimit(now: Date) -> Bool {
        if config.segmentCharacterLimit > 0 {
            let current = totalCharacterCount() - segmentBaselineLength
            if current >= config.segmentCharacterLimit {
                return true
            }
        }
        if let start = segmentStart, config.segmentDurationMs > 0 {
            let elapsed = now.timeIntervalSince(start) * 1000
            if elapsed >= Double(config.segmentDurationMs) {
                return true
            }
        }
        return false
    }

    private func recordFailure() {
        lastStopReason = .error
        emitter.emit(.stopped)
    }

    private func cleanupAfterFailure() {
        recognizer.stopStream()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func emitTranscript() {
        emitter.emit(.transcriptUpdated)
    }
}

final class SpeechRecognizer: NSObject, SFSpeechRecognizerDelegate {
    private var bus = 0
    private var size: UInt32 = 1024
    private var engine = AVAudioEngine()
    private var requests: [UUID: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var streaming = false

    typealias SpeechRecognitionCallback = (
        _ transcripts: [String],
        _ isFinal: Bool,
        _ locale: LangLocale,
        _ confidence: Double
    ) -> Void

    static func requestAuthorization(
        completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status)
        }
    }


    func stopStream() {
        engine.stop()
        engine.inputNode.removeTap(onBus: bus)
        detach()
        streaming = false
    }

    func startStream() throws {
        if streaming {
            return
        }
        engine.inputNode.removeTap(onBus: bus)
        engine.inputNode.installTap(
            onBus: bus,
            bufferSize: size,
            format: engine.inputNode.outputFormat(forBus: bus)
        ) { buffer, _ in
            self.requests.forEach { _, request in
                request.append(buffer)
            }
        }
        engine.prepare()
        try engine.start()
        streaming = true
    }

    func detach() {
        let ids = Array(requests.keys)
        ids.forEach { id in
            finish(id: id, stopEngine: false)
        }
    }

    func attach(
        _ ll: LangLocale,
        callback: @escaping SpeechRecognitionCallback
    ) throws {
        let id = UUID()
        try attachInternal(id: id, ll: ll, stopEngine: true, callback: callback)
    }

    func startContinuous(
        _ ll: LangLocale,
        callback: @escaping SpeechRecognitionCallback
    ) throws -> UUID {
        let id = UUID()
        try attachInternal(id: id, ll: ll, stopEngine: false, callback: callback)
        return id
    }

    func stopContinuous(_ id: UUID) {
        finish(id: id, stopEngine: false)
    }

    private func attachInternal(
        id: UUID,
        ll: LangLocale,
        stopEngine: Bool,
        callback: @escaping SpeechRecognitionCallback
    ) throws {
        let identifier = langLocaleToString(ll)
        let locale = Locale(identifier: identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw NSError(domain: "SpeechRecognizer", code: -1, userInfo: nil)
        }
        recognizer.defaultTaskHint = .dictation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        requests[id] = request
        let task = recognizer.recognitionTask(with: request) { result, error in
            if self.requests[id] == nil {
                return
            }
            if let result {
                let bestString = result.bestTranscription.formattedString
                let alternatives = result.transcriptions.map { $0.formattedString }
                let segmentConfidence = result.bestTranscription.segments.last?.confidence ?? -1
                callback(
                    Array(Set([bestString] + alternatives)),
                    result.isFinal,
                    ll,
                    Double(segmentConfidence)
                )
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    self.finish(id: id, stopEngine: stopEngine)
                }
            }
        }
        tasks[id] = task
    }

    private func finish(id: UUID, stopEngine: Bool) {
        guard requests[id] != nil else {
            return
        }
        requests[id]?.endAudio()
        requests[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        if stopEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: bus)
            streaming = false
        }
    }
}

@MainActor
final class AudioPlayer {
    private var players: [UUID: AVPlayer] = [:]
    private var completions: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var observers: [UUID: [NSObjectProtocol]] = [:]

    func pauseAll() {
        let ids = Array(players.keys)
        for id in ids {
            players[id]?.pause()
        }
    }

    func resumeAll() {
        let ids = Array(players.keys)
        for id in ids {
            players[id]?.play()
        }
    }

    func stopAll() {
        let ids = Array(players.keys)
        for id in ids {
            players[id]?.pause()
            complete(id: id, result: .success(()))
        }
    }

    func playAudioFromURL(_ urlString: String, volume: Float) async throws {
        guard let url = URL(string: urlString) else {
            throw NSError(
                domain: "AudioPlayer",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load audio URL"]
            )
        }

        let id = UUID()
        let player = AVPlayer(url: url)
        player.volume = volume
        configurePlayer(player)
        players[id] = player
        observe(player: player, id: id)
        player.play()

        try await withCheckedThrowingContinuation { continuation in
            completions[id] = { result in
                continuation.resume(with: result)
            }
        }
    }

    private func configurePlayer(_ player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
    }

    private func observe(player: AVPlayer, id: UUID) {
        var tokens: [NSObjectProtocol] = []
        if let item = player.currentItem {
            let endToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.complete(id: id, result: .success(()))
            }
            tokens.append(endToken)

            let failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let fallback = NSError(
                    domain: "AudioPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Playback failed"]
                )
                self?.complete(id: id, result: .failure(error ?? fallback))
            }
            tokens.append(failToken)

            let stallToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { _ in
                player.play()
            }
            tokens.append(stallToken)
        }
        observers[id] = tokens
    }

    private func complete(id: UUID, result: Result<Void, Error>) {
        guard let completion = completions[id] else {
            cleanupPlayer(id: id)
            return
        }
        completions[id] = nil
        cleanupPlayer(id: id)
        completion(result)
    }

    private func cleanupPlayer(id: UUID) {
        observers[id]?.forEach { NotificationCenter.default.removeObserver($0) }
        observers[id] = nil
        players[id] = nil
    }
}

class EventEmitter<Event: Hashable> {
    private var listeners: [Event: [(once: Bool, callback: () -> Void)]] = [:]

    func on(_ event: Event, _ callback: @escaping () -> Void) {
        listeners[event, default: []].append((once: false, callback: callback))
    }

    func once(_ event: Event, _ callback: @escaping () -> Void) {
        listeners[event, default: []].append((once: true, callback: callback))
    }

    func emit(_ event: Event) {
        guard let callbacks = listeners[event] else {
            return
        }
        for entry in callbacks {
            entry.callback()
        }
        listeners[event] = callbacks.filter { !$0.once }
    }

    func removeAllListeners(_ event: Event) {
        listeners[event] = []
    }

    func removeAllListeners() {
        listeners = [:]
    }
}
