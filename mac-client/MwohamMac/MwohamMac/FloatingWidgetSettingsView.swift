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
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                            ],
                            spacing: 8
                        ) {
                            ForEach(FloatingWidgetAccentColor.allCases) { preset in
                                accentPresetButton(preset)
                            }
                        }
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
        .background(settingsBackground)
        .background(WindowBackgroundConfigurator())
        .tint(store.settings.accentColor.accentColor)
    }

    private var settingsBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(store.settings.opacity)
            store.settings.accentColor.subtleBackgroundColor
        }
    }

    private func accentPresetButton(
        _ preset: FloatingWidgetAccentColor
    ) -> some View {
        let isSelected = store.settings.accentColor == preset
        return Button {
            store.settings.accentColor = preset
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(preset.accentColor)
                    .frame(width: 9, height: 9)
                Text(preset.title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .frame(width: 10)
                } else {
                    Color.clear
                        .frame(width: 10, height: 10)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? preset.subtleBackgroundColor : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isSelected ? preset.borderColor : Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
    }
}

private struct WindowBackgroundConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(from: nsView)
    }

    private func configure(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.isOpaque = false
            view.window?.backgroundColor = .clear
            view.window?.alphaValue = 1.0
        }
    }
}
