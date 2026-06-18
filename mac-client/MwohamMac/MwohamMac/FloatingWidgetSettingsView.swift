//
//  FloatingWidgetSettingsView.swift
//  MwohamMac
//

import AppKit
import SwiftUI

struct FloatingWidgetSettingsView: View {
    @ObservedObject var store: FloatingWidgetSettingsStore
    @Environment(\.dismiss) private var dismiss

    private var opacityPercent: Int {
        Int((store.settings.opacity * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("위젯 설정")
                .font(.title3)
                .fontWeight(.semibold)

            GroupBox("모양") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("투명도")
                            Spacer()
                            Text("\(opacityPercent)%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $store.settings.opacity,
                            in: FloatingWidgetSettings.opacityRange
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("색상")
                        Picker("색상", selection: $store.settings.accentColor) {
                            ForEach(FloatingWidgetAccentColor.allCases) { preset in
                                Text(preset.title)
                                    .tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("표시 항목") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("현재 앱", isOn: $store.settings.showsCurrentApp)
                    Toggle("현재 창", isOn: $store.settings.showsCurrentWindow)
                    Toggle("OCR 상태", isOn: $store.settings.showsOCRStatus)
                    Toggle(
                        "Dev Tracking 상태",
                        isOn: $store.settings.showsDevTrackingStatus
                    )
                    Toggle("기록 시간", isOn: $store.settings.showsElapsedTime)
                }
                .padding(.vertical, 4)
            }

            GroupBox("빠른 액션") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "메인 창 열기",
                        isOn: $store.settings.showsOpenMainWindowAction
                    )
                    Toggle(
                        "대시보드 열기",
                        isOn: $store.settings.showsOpenDashboardAction
                    )
                    Toggle(
                        "Dev Tracking 시작/중지",
                        isOn: $store.settings.showsDevTrackingAction
                    )
                    Toggle(
                        "회의모드 시작/중지",
                        isOn: $store.settings.showsMeetingModeAction
                    )
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("기본값으로 초기화") {
                    store.resetToDefaults()
                }

                Spacer()

                Button("닫기") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            WindowOpacityApplier(opacity: store.settings.opacity)
                .frame(width: 0, height: 0)
        )
        .tint(store.settings.accentColor.color)
    }
}

private struct WindowOpacityApplier: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        applyOpacity(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyOpacity(from: nsView)
    }

    private func applyOpacity(from view: NSView) {
        let clampedOpacity = FloatingWidgetSettings.clampedOpacity(opacity)
        DispatchQueue.main.async {
            view.window?.alphaValue = clampedOpacity
        }
    }
}
