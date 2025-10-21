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

private struct TranslationRequest: Equatable {
    let ids: [UUID]
    let texts: [String]
    let sl: LangLocale
    let tl: LangLocale
    let instruction: String
}

struct HomeView: View {
    @StateObject private var ctrl: SpeechCaptureController
    @State private var sl: LangLocale
    @State private var tl: LangLocale
    @State private var translations: [UUID: LineTranslation]
    @State private var pendingIds: Set<UUID> = []
    @State private var activeRequest: TranslationRequest?
    @State private var queuedRequest: TranslationRequest?
    @State private var activeToken: UUID?
    @State private var settings: HomeSettings
    @State private var showSettings: Bool
    private let translator: TranslationService?
    private let translationWindow = 3

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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            if ctrl.lines.isEmpty {
                                Text(ctrl.isRecording ? "Listening" : "Press start to capture speech")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(ctrl.lines) { line in
                                    let pending = pendingIds.contains(line.id)
                                    let translation = translations[line.id]?.value ?? ""
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(displayText(line))
                                            .font(.system(size: 18 * settings.fontScale))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !translation.isEmpty {
                                            Text(translation)
                                                .font(.system(size: 17 * settings.fontScale))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(12)
                                    .overlay(alignment: .topTrailing) {
                                        if pending {
                                            PulseDots()
                                                .frame(width: 20)
                                                .padding(12)
                                        }
                                    }
                                    .id(line.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical)
                    }
                    .onChange(of: ctrl.lines) { lines in
                        guard let last = lines.last else {
                            return
                        }
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = ctrl.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
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
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: ctrl.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 28, weight: .bold))
                        Text(ctrl.isRecording ? "Stop" : "Start")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ctrl.isRecording ? Color.red : Color.accentColor)
                    .cornerRadius(16)
                }
                .padding(.top, 0)
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
        pendingIds = []
        activeRequest = nil
        queuedRequest = nil
        activeToken = nil
    }

    @MainActor private func updateTranslations() {
        let ids = Set(ctrl.lines.map { $0.id })
        pruneTranslations(ids)
        guard let service = translator, sl != tl else {
            resetTranslations()
            return
        }
        let hint = String(settings.instruction.prefix(100))
        var rows: [(UUID, String)] = []
        for line in ctrl.lines {
            let id = line.id
            let text = trimmed(line)
            if text.isEmpty {
                translations[id] = nil
                continue
            }
            rows.append((id, text))
        }
        if rows.isEmpty {
            pendingIds = []
            return
        }
        let subset = Array(rows.suffix(translationWindow))
        var needsWork = false
        for entry in subset {
            if let existing = translations[entry.0], existing.text == entry.1, !existing.value.isEmpty {
                continue
            }
            needsWork = true
            break
        }
        if !needsWork {
            return
        }
        let request = TranslationRequest(
            ids: subset.map { $0.0 },
            texts: subset.map { $0.1 },
            sl: sl,
            tl: tl,
            instruction: hint
        )
        if let active = activeRequest, active == request {
            return
        }
        if let queued = queuedRequest, queued == request {
            return
        }
        if activeToken == nil {
            startTranslation(request, service: service)
        } else {
            queuedRequest = request
            pendingIds.formUnion(request.ids)
        }
    }

    @MainActor private func startTranslation(_ request: TranslationRequest, service: TranslationService) {
        let token = UUID()
        activeToken = token
        activeRequest = request
        pendingIds = Set(request.ids)
        Task {
            let result = await service.translate(
                lines: request.texts,
                sl: request.sl,
                tl: request.tl,
                instruction: request.instruction
            )
            await MainActor.run {
                guard activeToken == token else {
                    return
                }
                activeToken = nil
                activeRequest = nil
                pendingIds = []
                if let output = result,
                   translator != nil,
                   sl == request.sl,
                   tl == request.tl,
                   String(settings.instruction.prefix(100)) == request.instruction,
                   !output.isEmpty,
                   output.count == request.ids.count {
                    for index in 0..<request.ids.count {
                        let id = request.ids[index]
                        let source = request.texts[index]
                        let latest = trimmed(id: id)
                        if latest.isEmpty || !latest.hasPrefix(source) {
                            continue
                        }
                        let translated = output[index].trimmingCharacters(in: .whitespacesAndNewlines)
                        if translated.isEmpty {
                            translations[id] = nil
                        } else {
                            translations[id] = LineTranslation(text: source, value: translated)
                        }
                    }
                }
                let next = queuedRequest
                queuedRequest = nil
                if let next, let svc = translator, sl != tl {
                    startTranslation(next, service: svc)
                }
            }
        }
    }

    @MainActor private func pruneTranslations(_ ids: Set<UUID>) {
        translations = translations.filter { ids.contains($0.key) }
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
