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

            GroupBox("안내") {
                Text("표시 항목과 빠른 액션 설정은 다음 단계에서 지원합니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
