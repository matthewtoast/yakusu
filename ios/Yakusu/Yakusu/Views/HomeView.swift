import SwiftUI

private struct PulseDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1 : 0.4)
                    .opacity(animate ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: animate
                    )
            }
        }
        .onAppear {
            animate = true
        }
        .onDisappear {
            animate = false
        }
    }
}

private struct SignalBadge: View {
    let value: Double

    var body: some View {
        if value < 0 {
            EmptyView()
        } else {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .clipShape(Capsule())
        }
    }

    private var label: String {
        if value >= 0.66 {
            return "High"
        }
        if value >= 0.33 {
            return "Med"
        }
        return "Low"
    }

    private var color: Color {
        if value >= 0.66 {
            return .green
        }
        if value >= 0.33 {
            return .orange
        }
        return .red
    }
}

private struct HomeSettings: Equatable {
    var fontScale: Double
    var instruction: String
    var lineGapMs: Int
    var maxDurationMs: Int
    var segmentDurationMs: Int
    var segmentCharacterLimit: Int
    var autoStopAfterMs: Int
}

private struct SettingsPanel: View {
    @Binding var settings: HomeSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    VStack(alignment: .leading, spacing: 12) {
                        Slider(value: $settings.fontScale, in: 0.7...1.5, step: 0.05)
                        Text(String(format: "%.2fx", settings.fontScale))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Section("Translation") {
                    TextField("Custom guidance", text: $settings.instruction, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                    Text("\(settings.instruction.count)/100")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Capture") {
                    Stepper("Gap (ms): \(settings.lineGapMs)", value: $settings.lineGapMs, in: 100...5000, step: 100)
                    Stepper("Max duration (ms): \(settings.maxDurationMs)", value: $settings.maxDurationMs, in: 60000...900000, step: 60000)
                    Stepper("Segment duration (ms): \(settings.segmentDurationMs)", value: $settings.segmentDurationMs, in: 30000...300000, step: 30000)
                    Stepper("Segment limit: \(settings.segmentCharacterLimit)", value: $settings.segmentCharacterLimit, in: 500...8000, step: 100)
                    Stepper("Auto stop (ms): \(settings.autoStopAfterMs)", value: $settings.autoStopAfterMs, in: 0...600000, step: 5000)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: settings.instruction) { value in
            if value.count > 100 {
                settings.instruction = String(value.prefix(100))
            }
        }
    }
}

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
    @State private var settings: HomeSettings
    @State private var showSettings: Bool
    private let translator: TranslationService?

    init() {
        let initialSL: LangLocale = .ja_jp
        let initialTL: LangLocale = .en_us
        let defaults = HomeSettings(
            fontScale: 1,
            instruction: "",
            lineGapMs: 1500,
            maxDurationMs: 600000,
            segmentDurationMs: 120000,
            segmentCharacterLimit: 4000,
            autoStopAfterMs: 0
        )
        _sl = State(initialValue: initialSL)
        _tl = State(initialValue: initialTL)
        _translations = State(initialValue: [:])
        _inFlight = State(initialValue: [:])
        _waiters = State(initialValue: [:])
        _settings = State(initialValue: defaults)
        _showSettings = State(initialValue: false)
        if let base = AppConfig.apiBaseURL {
            translator = TranslationService(baseURL: base)
        } else {
            translator = nil
        }
        let config = SpeechCaptureConfig(
            lineGapMs: defaults.lineGapMs,
            maxDurationMs: defaults.maxDurationMs,
            segmentDurationMs: defaults.segmentDurationMs,
            segmentCharacterLimit: defaults.segmentCharacterLimit,
            autoStopAfterMs: defaults.autoStopAfterMs
        )
        _ctrl = StateObject(wrappedValue: SpeechCaptureController(locale: initialSL, config: config))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .padding(8)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(Circle())
                    }
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
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(displayText(line))
                                            .font(.system(size: 18 * settings.fontScale))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        SignalBadge(value: line.confidence)
                                    }
                                    if let tr = translations[line.id], !tr.value.isEmpty {
                                        Text(tr.value)
                                            .font(.system(size: 17 * settings.fontScale))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundColor(.accentColor)
                                    } else if inFlight[line.id] != nil {
                                        PulseDots()
                                            .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(spacing: 12) {
                    Picker(selection: $sl) {
                        ForEach(LangLocale.allCases, id: \.self) { value in
                            Text(langLabel(value)).tag(value)
                        }
                    } label: {
                        Text("From: \(langLabel(sl))")
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
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
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
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
        .onChange(of: settings.lineGapMs) { _ in
            applyCaptureSettings()
        }
        .onChange(of: settings.maxDurationMs) { _ in
            applyCaptureSettings()
        }
        .onChange(of: settings.segmentDurationMs) { _ in
            applyCaptureSettings()
        }
        .onChange(of: settings.segmentCharacterLimit) { _ in
            applyCaptureSettings()
        }
        .onChange(of: settings.autoStopAfterMs) { _ in
            applyCaptureSettings()
        }
        .onChange(of: settings.instruction) { _ in
            resetTranslations()
            updateTranslations()
        }
        .task {
            updateTranslations()
        }
        .sheet(isPresented: $showSettings) {
            SettingsPanel(settings: $settings)
        }
    }

    private func langLabel(_ locale: LangLocale) -> String {
        langLocaleToName(locale)
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

    private func makeConfig(_ value: HomeSettings) -> SpeechCaptureConfig {
        SpeechCaptureConfig(
            lineGapMs: value.lineGapMs,
            maxDurationMs: value.maxDurationMs,
            segmentDurationMs: value.segmentDurationMs,
            segmentCharacterLimit: value.segmentCharacterLimit,
            autoStopAfterMs: value.autoStopAfterMs
        )
    }

    private func applyCaptureSettings() {
        let config = makeConfig(settings)
        ctrl.updateConfig(config)
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
        let hint = String(settings.instruction.prefix(100))
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
            scheduleTranslation(for: id, text: text, service: service, instruction: hint)
        }
    }

    @MainActor private func scheduleTranslation(for id: UUID, text: String, service: TranslationService, instruction: String) {
        cancelWaiter(id)
        let task = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled {
                return
            }
            let snapshot = await MainActor.run { () -> (TranslationService, String, LangLocale, LangLocale, String)? in
                guard ctrl.lines.contains(where: { $0.id == id }) else {
                    return nil
                }
                return (service, trimmed(id: id), sl, tl, instruction)
            }
            guard let (service, latest, source, target, hint) = snapshot else {
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
            let result = await service.translate(text: text, sl: source, tl: target, instruction: hint)
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                inFlight[id] = nil
                guard ctrl.lines.contains(where: { $0.id == id }) else {
                    translations[id] = nil
                    return
                }
                if translator == nil || sl != source || tl != target || settings.instruction != hint {
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
