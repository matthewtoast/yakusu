import SwiftUI

struct HomeView: View {
    @StateObject private var ctrl: SpeechCaptureController
    private let cfg: SpeechCaptureConfig

    init() {
        let cfg = SpeechCaptureConfig(
            lineGapMs: 1500,
            maxDurationMs: 600000,
            segmentDurationMs: 120000,
            segmentCharacterLimit: 4000,
            autoStopAfterMs: 0
        )
        self.cfg = cfg
        _ctrl = StateObject(wrappedValue: SpeechCaptureController(locale: .en_us, config: cfg))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                ScrollView {
                    VStack(spacing: 12) {
                        if ctrl.lines.isEmpty {
                            Text(ctrl.isRecording ? "Listening" : "Press start to capture speech")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(ctrl.lines) { line in
                                Text(lineText(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Gap \(cfg.lineGapMs) ms")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    private func lineText(_ line: SpeechCaptureLine) -> String {
        let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "Listening"
        }
        return value
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

