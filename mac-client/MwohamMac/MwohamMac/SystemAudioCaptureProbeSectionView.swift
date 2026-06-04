//
//  SystemAudioCaptureProbeSectionView.swift
//  MwohamMac
//

import SwiftUI

struct SystemAudioCaptureProbeSectionView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("시스템 오디오 캡처 테스트")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.startSystemAudioCaptureProbe()
                    }
                } label: {
                    Label("테스트 시작", systemImage: "waveform.circle")
                }
                .disabled(viewModel.isSystemAudioCaptureProbeRunning)

                Button {
                    Task {
                        await viewModel.stopSystemAudioCaptureProbe()
                    }
                } label: {
                    Label("테스트 종료", systemImage: "stop.circle")
                }
                .disabled(!viewModel.isSystemAudioCaptureProbeRunning)

                Button {
                    viewModel.openScreenRecordingSettings()
                } label: {
                    Label("화면 기록 설정 열기", systemImage: "gearshape")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("캡처 상태")
                        .foregroundStyle(.secondary)
                    Text(viewModel.systemAudioCaptureStatus)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.startSystemAudioSpeechProbe()
                    }
                } label: {
                    Label("시스템 오디오 전사 테스트 시작", systemImage: "captions.bubble")
                }
                .disabled(viewModel.isSystemAudioSpeechProbeRunning)

                Button {
                    Task {
                        await viewModel.stopSystemAudioSpeechProbe()
                    }
                } label: {
                    Label("시스템 오디오 전사 테스트 종료", systemImage: "stop.circle")
                }
                .disabled(!viewModel.isSystemAudioSpeechProbeRunning)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("전사 상태")
                        .foregroundStyle(.secondary)
                    Text(viewModel.systemAudioSpeechStatus)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }

                GridRow {
                    Text("전사 결과")
                        .foregroundStyle(.secondary)
                    Text(systemAudioSpeechTranscript)
                        .fontWeight(.medium)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Text("개발 검증용입니다. 원본 오디오를 파일로 저장하지 않고 backend로 전송하지 않습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var systemAudioSpeechTranscript: String {
        viewModel.systemAudioSpeechTranscript.isEmpty
            ? "아직 시스템 오디오 전사 결과가 없습니다."
            : viewModel.systemAudioSpeechTranscript
    }
}
