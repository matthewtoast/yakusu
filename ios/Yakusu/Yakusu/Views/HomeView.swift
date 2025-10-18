import SwiftUI

private struct LineTranslation: Equatable {
    let text: String
    let value: String
}

struct HomeView: View {
    @StateObject private var ctrl: SpeechCaptureController
    @State private var sl: LangLocale
    @State private var tl: LangLocale
    @State private var translations: [UUID: LineTranslation]
    @State private var inFlight: [UUID: String]
    @State private var waiters: [UUID: Task<Void, Never>]
    private let cfg: SpeechCaptureConfig
    private let translator: TranslationService?

    init() {
        let cfg = SpeechCaptureConfig(
            lineGapMs: 1500,
            maxDurationMs: 600000,
            segmentDurationMs: 120000,
            segmentCharacterLimit: 4000,
            autoStopAfterMs: 0
        )
        let initialSL: LangLocale = .en_us
        let initialTL: LangLocale = .es_es
        self.cfg = cfg
        _sl = State(initialValue: initialSL)
        _tl = State(initialValue: initialTL)
        _translations = State(initialValue: [:])
        _inFlight = State(initialValue: [:])
        _waiters = State(initialValue: [:])
        if let base = AppConfig.apiBaseURL {
            translator = TranslationService(baseURL: base)
        } else {
            translator = nil
        }
        _ctrl = StateObject(wrappedValue: SpeechCaptureController(locale: initialSL, config: cfg))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Picker(selection: $sl) {
                        ForEach(LangLocale.allCases, id: \.self) { value in
                            Text(langLabel(value)).tag(value)
                        }
                    } label: {
                        Text("From: \(langLabel(sl))")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .pickerStyle(.menu)
                    Button(action: swapLanguages) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(10)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Circle())
                    }
                    Picker(selection: $tl) {
                        ForEach(LangLocale.allCases, id: \.self) { value in
                            Text(langLabel(value)).tag(value)
                        }
                    } label: {
                        Text("To: \(langLabel(tl))")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .pickerStyle(.menu)
                }
                ScrollView {
                    VStack(spacing: 12) {
                        if ctrl.lines.isEmpty {
                            Text(ctrl.isRecording ? "Listening" : "Press start to capture speech")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(ctrl.lines) { line in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(displayText(line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let tr = translations[line.id], !tr.value.isEmpty {
                                        Text(tr.value)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical)
                }
                Spacer(minLength: 16)
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: ctrl.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 28, weight: .bold))
                        Text(ctrl.isRecording ? "Stop" : "Start")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(ctrl.isRecording ? Color.red : Color.accentColor)
                    .cornerRadius(16)
                }
            }
            .padding()
        }
        .onChange(of: ctrl.lines) { _ in
            updateTranslations()
        }
        .onChange(of: ctrl.isRecording) { _ in
            updateTranslations()
        }
        .onChange(of: sl) { value in
            ctrl.setLocale(value)
            resetTranslations()
            updateTranslations()
        }
        .onChange(of: tl) { _ in
            resetTranslations()
            updateTranslations()
        }
        .task {
            updateTranslations()
        }
    }

    private func langLabel(_ locale: LangLocale) -> String {
        "\(langLocaleToFlag(locale)) \(langLocaleToName(locale))"
    }

    private func trimmed(_ line: SpeechCaptureLine) -> String {
        line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmed(id: UUID) -> String {
        guard let line = ctrl.lines.first(where: { $0.id == id }) else {
            return ""
        }
        return trimmed(line)
    }

    private func displayText(_ line: SpeechCaptureLine) -> String {
        let value = trimmed(line)
        if value.isEmpty {
            return "Listening"
        }
        return value
    }

    @MainActor private func resetTranslations() {
        translations = [:]
        inFlight = [:]
        let keys = Array(waiters.keys)
        for key in keys {
            cancelWaiter(key)
        }
    }

    @MainActor private func cancelWaiter(_ id: UUID) {
        waiters[id]?.cancel()
        waiters[id] = nil
    }

    @MainActor private func updateTranslations() {
        let ids = Set(ctrl.lines.map { $0.id })
        pruneTranslations(ids)
        guard let service = translator, sl != tl else {
            resetTranslations()
            return
        }
        for line in ctrl.lines {
            let id = line.id
            let text = trimmed(line)
            if text.isEmpty {
                translations[id] = nil
                inFlight[id] = nil
                cancelWaiter(id)
                continue
            }
            if let entry = translations[id], entry.text == text {
                continue
            }
            if inFlight[id] == text {
                continue
            }
            scheduleTranslation(for: id, text: text, service: service)
        }
    }

    @MainActor private func scheduleTranslation(for id: UUID, text: String, service: TranslationService) {
        cancelWaiter(id)
        let task = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled {
                return
            }
            let snapshot = await MainActor.run { () -> (TranslationService, String, LangLocale, LangLocale)? in
                guard ctrl.lines.contains(where: { $0.id == id }) else {
                    return nil
                }
                return (service, trimmed(id: id), sl, tl)
            }
            guard let (service, latest, source, target) = snapshot else {
                await MainActor.run {
                    inFlight[id] = nil
                    cancelWaiter(id)
                    translations[id] = nil
                }
                return
            }
            if latest.isEmpty {
                await MainActor.run {
                    inFlight[id] = nil
                    cancelWaiter(id)
                    translations[id] = nil
                }
                return
            }
            if latest != text {
                await MainActor.run {
                    cancelWaiter(id)
                }
                return
            }
            await MainActor.run {
                waiters[id] = nil
                inFlight[id] = text
            }
            let result = await service.translate(text: text, sl: source, tl: target)
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                inFlight[id] = nil
                guard ctrl.lines.contains(where: { $0.id == id }) else {
                    translations[id] = nil
                    return
                }
                if translator == nil || sl != source || tl != target {
                    return
                }
                let latestValue = trimmed(id: id)
                if latestValue != text {
                    translations[id] = nil
                    Task { @MainActor in
                        updateTranslations()
                    }
                    return
                }
                guard let value = result else {
                    translations[id] = nil
                    return
                }
                translations[id] = LineTranslation(text: text, value: value)
            }
        }
        waiters[id] = task
    }

    @MainActor private func pruneTranslations(_ ids: Set<UUID>) {
        translations = translations.filter { ids.contains($0.key) }
        inFlight = inFlight.filter { ids.contains($0.key) }
        let stale = waiters.keys.filter { !ids.contains($0) }
        for id in stale {
            cancelWaiter(id)
        }
    }

    @MainActor private func swapLanguages() {
        if sl == tl {
            return
        }
        let next = sl
        sl = tl
        tl = next
    }

    private func toggle() {
        if ctrl.isRecording {
            ctrl.stop(reason: .user)
            return
        }
        Task {
            await ctrl.start()
        }
    }
}
