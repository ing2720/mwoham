//
//  CommonUIComponents.swift
//  MwohamMac
//

import SwiftUI

struct StatusBadge<State: StatusPresentable>: View {
    let state: State
    var compact = false

    var body: some View {
        Label(state.label, systemImage: state.systemImage)
            .font(compact ? .caption : .callout)
            .fontWeight(.medium)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 3 : 5)
            .background(backgroundStyle, in: Capsule())
            .accessibilityLabel(state.label)
    }

    private var foregroundStyle: Color {
        if state.isError {
            return .red
        }
        if state.isRunning {
            return .green
        }
        return .secondary
    }

    private var backgroundStyle: Color {
        foregroundStyle.opacity(0.12)
    }
}

struct StatusCard<Content: View>: View {
    let title: String
    let systemImage: String?
    let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    var isDisabled = false
    var fillsWidth = false
    let action: () async -> Void

    var body: some View {
        Button(role: role) {
            Task {
                await action()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

enum RecordingControlStyle: Equatable {
    case standard
    case compact
    case menu
}

struct RecordingControl: View {
    @ObservedObject var viewModel: RecordingViewModel
    var style: RecordingControlStyle = .standard
    var fillsWidth = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .stopped:
                actionButton(.start)
            case .active:
                if style == .compact {
                    actionButton(.pause)
                } else if style == .menu {
                    actionButton(.pause)
                    actionButton(.stop)
                } else {
                    HStack(spacing: 8) {
                        actionButton(.pause)
                        actionButton(.stop)
                    }
                }
            case .paused:
                if style == .compact {
                    actionButton(.resume)
                } else if style == .menu {
                    actionButton(.resume)
                    actionButton(.stop)
                } else {
                    HStack(spacing: 8) {
                        actionButton(.resume)
                        actionButton(.stop)
                    }
                }
            case .unknown:
                EmptyView()
            }
        }
        .controlSize(style == .compact ? .small : .regular)
    }

    @ViewBuilder
    private func actionButton(_ action: RecordingControlAction) -> some View {
        if style == .menu {
            Button(action.title, role: action.role) {
                Task {
                    await perform(action)
                }
            }
            .disabled(!isEnabled(action))
            .accessibilityLabel(action.title)
        } else {
            PrimaryActionButton(
                title: action.title,
                systemImage: action.systemImage,
                role: action.role,
                isDisabled: !isEnabled(action),
                fillsWidth: fillsWidth
            ) {
                await perform(action)
            }
        }
    }

    private func isEnabled(_ action: RecordingControlAction) -> Bool {
        switch action {
        case .start:
            return viewModel.canStart
        case .pause:
            return viewModel.canPause
        case .resume:
            return viewModel.canResume
        case .stop:
            return viewModel.canStop
        }
    }

    private func perform(_ action: RecordingControlAction) async {
        switch action {
        case .start:
            await viewModel.start()
        case .pause:
            await viewModel.pause()
        case .resume:
            await viewModel.resume()
        case .stop:
            await viewModel.stop()
        }
    }
}

private enum RecordingControlAction {
    case start
    case pause
    case resume
    case stop

    var title: String {
        switch self {
        case .start:
            return "기록 시작"
        case .pause:
            return "일시정지"
        case .resume:
            return "재개"
        case .stop:
            return "기록 종료"
        }
    }

    var systemImage: String {
        switch self {
        case .start:
            return "record.circle"
        case .pause:
            return "pause.circle"
        case .resume:
            return "play.circle"
        case .stop:
            return "stop.circle"
        }
    }

    var role: ButtonRole? {
        self == .stop ? .destructive : nil
    }
}

struct ErrorBanner: View {
    let message: String
    var title = "오류가 발생했습니다"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
