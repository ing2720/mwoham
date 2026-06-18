//
//  FloatingWidgetView.swift
//  MwohamMac
//

import AppKit
import SwiftUI

struct FloatingWidgetView: View {
    static let minimumContentSize = CGSize(width: 214, height: 80)

    @ObservedObject var viewModel: BackendStatusViewModel
    @ObservedObject var settingsStore: FloatingWidgetSettingsStore
    var onResizeRequest: (FloatingWidgetResizeTarget) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow
    @State private var isSettingsPresented = false

    private var presentation: MenuBarFloatingPresentation {
        MenuBarFloatingPresentation(
            provider: viewModel,
            isFloatingWidgetVisible: true
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutMode = resolvedLayoutMode(for: proxy.size)
            content(for: layoutMode, size: proxy.size)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(
            minWidth: Self.minimumContentSize.width,
            minHeight: Self.minimumContentSize.height
        )
        .tint(settingsStore.settings.accentColor.color)
        .sheet(isPresented: $isSettingsPresented) {
            FloatingWidgetSettingsView(store: settingsStore)
        }
    }

    @ViewBuilder
    private func content(
        for layoutMode: MenuBarFloatingPresentation.FloatingWidgetLayoutMode,
        size: CGSize
    ) -> some View {
        if size.width <= 240 && size.height <= 140 {
            narrowWidthView
        } else {
            switch layoutMode {
            case .veryCompact:
                veryCompactView

            case .compact:
                adaptiveWidgetContent(
                    layoutMode: .compact,
                    visibility: WidgetVisibility(size: size),
                    rowSpacing: 5,
                    sectionSpacing: 8,
                    usesRelaxedSpacing: false
                )
            case .regular:
                adaptiveWidgetContent(
                    layoutMode: .regular,
                    visibility: WidgetVisibility(size: size),
                    rowSpacing: 6,
                    sectionSpacing: 10,
                    usesRelaxedSpacing: false
                )
            case .spacious:
                adaptiveWidgetContent(
                    layoutMode: .spacious,
                    visibility: WidgetVisibility(size: size),
                    rowSpacing: 6,
                    sectionSpacing: 8,
                    usesRelaxedSpacing: true
                )
            }
        }
    }

    private func resolvedLayoutMode(
        for size: CGSize
    ) -> MenuBarFloatingPresentation.FloatingWidgetLayoutMode {
        return MenuBarFloatingPresentation.FloatingWidgetLayoutMode.mode(
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private var veryCompactView: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView(layoutMode: .veryCompact, isNarrowWidth: true)

            RecordingControl(
                viewModel: viewModel.recording,
                style: .condensed,
                fillsWidth: true
            )
            .buttonStyle(
                FloatingWidgetActionButtonStyle(
                    accentColor: settingsStore.settings.accentColor.color
                )
            )
        }
        .padding(8)
    }

    private var narrowWidthView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusBadge(state: presentation.recordingState, compact: true)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                if settingsStore.settings.showsElapsedTime {
                    Text(presentation.recordingElapsedTimeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }

                Spacer(minLength: 2)

                Button {
                    onResizeRequest(.standard)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("표준 크기")
                .accessibilityLabel("표준 크기")
            }

            RecordingControl(
                viewModel: viewModel.recording,
                style: .condensed,
                fillsWidth: true
            )
            .buttonStyle(
                FloatingWidgetActionButtonStyle(
                    accentColor: settingsStore.settings.accentColor.color
                )
            )
        }
        .padding(8)
    }

    private func adaptiveWidgetContent(
        layoutMode: MenuBarFloatingPresentation.FloatingWidgetLayoutMode,
        visibility: WidgetVisibility,
        rowSpacing: CGFloat,
        sectionSpacing: CGFloat,
        usesRelaxedSpacing: Bool
    ) -> some View {
        let displayPolicy = displayPolicy(for: visibility)

        return VStack(alignment: .leading, spacing: sectionSpacing) {
            headerView(layoutMode: layoutMode,
                       isNarrowWidth: visibility.usesNarrowHeader
                   )

            VStack(alignment: .leading, spacing: rowSpacing) {
                if displayPolicy.showsCompactActivity {
                    Text(presentation.compactCurrentActivityText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if displayPolicy.showsCurrentApp {
                    FloatingStatusRow(
                        title: "현재 앱",
                        value: presentation.currentAppText
                    )
                }
                if displayPolicy.showsCurrentWindow {
                    FloatingStatusRow(
                        title: "현재 창",
                        value: presentation.currentWindowText
                    )
                }
                if displayPolicy.showsOCRStatus {
                    FloatingStatusBadgeRow(
                        title: presentation.ocrTitle,
                        state: presentation.ocrState
                    )
                }
                if displayPolicy.showsDevTrackingRow {
                    FloatingDevTrackingRow(presentation: presentation)
                } else if displayPolicy.showsDevTrackingBadge {
                    DevTrackingCompactBadge(
                        text: presentation.devTrackingDisplayText,
                        state: presentation.devTrackingBadgeState
                    )
                }
            }

            if visibility.showsActiveWindowTracking {
                FloatingStatusBadgeRow(
                    title: presentation.activeWindowTrackingTitle,
                    state: presentation.activeWindowTrackingState
                )
            }

            if visibility.pushesRecordingControlToBottom {
                Spacer(minLength: 0)
            }

            Divider()
            RecordingControl(
                viewModel: viewModel.recording,
                style: visibility.usesCondensedRecordingControl
                    ? .condensed
                    : .standard,
                fillsWidth: true
            )
            .buttonStyle(
                FloatingWidgetActionButtonStyle(
                    accentColor: settingsStore.settings.accentColor.color
                )
            )

            actionControls(displayPolicy: displayPolicy)
        }
        .padding(visibility.contentPadding(defaultPadding: usesRelaxedSpacing ? 18 : 14))
    }

    @ViewBuilder
    private func actionControls(
        displayPolicy: FloatingWidgetDisplayPolicy
    ) -> some View {
        if displayPolicy.showsAnyQuickAction {
            if displayPolicy.usesSingleColumnActions {
                singleColumnActionControls(displayPolicy: displayPolicy)
            } else {
                multiColumnActionControls(displayPolicy: displayPolicy)
            }
        }
    }

    private func singleColumnActionControls(
        displayPolicy: FloatingWidgetDisplayPolicy
    ) -> some View {
        VStack(spacing: 8) {
            if displayPolicy.showsDevTrackingAction {
                devTrackingToggleButton
            }

            if displayPolicy.showsMeetingModeAction {
                meetingModeToggleButton
            }

            if displayPolicy.showsOpenMainWindowAction {
                openMainWindowButton
            }

            if displayPolicy.showsOpenDashboardAction {
                openDashboardButton
            }
        }
        .buttonStyle(
            FloatingWidgetActionButtonStyle(
                accentColor: settingsStore.settings.accentColor.color
            )
        )
    }

    private func multiColumnActionControls(
        displayPolicy: FloatingWidgetDisplayPolicy
    ) -> some View {
        VStack(spacing: 8) {
            if displayPolicy.showsAnySecondaryAction {
                HStack(spacing: 8) {
                    if displayPolicy.showsDevTrackingAction {
                        devTrackingToggleButton
                    }

                    if displayPolicy.showsMeetingModeAction {
                        meetingModeToggleButton
                    }
                }
            }

            if displayPolicy.showsAnyOpenAction {
                HStack(spacing: 8) {
                    if displayPolicy.showsOpenMainWindowAction {
                        openMainWindowButton
                    }

                    if displayPolicy.showsOpenDashboardAction {
                        openDashboardButton
                    }
                }
            }
        }
        .buttonStyle(
            FloatingWidgetActionButtonStyle(
                accentColor: settingsStore.settings.accentColor.color
            )
        )
    }

    private func displayPolicy(
        for visibility: WidgetVisibility
    ) -> FloatingWidgetDisplayPolicy {
        FloatingWidgetDisplayPolicy(
            settings: settingsStore.settings,
            layout: FloatingWidgetLayoutAvailability(
                showsCompactActivity: visibility.showsCompactActivity,
                showsCurrentApp: visibility.showsCurrentApp,
                showsCurrentWindow: visibility.showsCurrentWindow,
                showsOCRStatus: visibility.showsOCR,
                showsDevTrackingRow: visibility.showsDevTrackingRow,
                showsDevTrackingBadge: visibility.showsDevTrackingBadge,
                showsElapsedTime: true,
                showsOpenMainWindowAction: visibility.showsOpenMainWindowAction,
                showsOpenDashboardAction: visibility.showsOpenDashboardAction,
                showsDevTrackingAction: visibility.showsDevTrackingAction,
                showsMeetingModeAction: visibility.showsMeetingModeAction,
                usesSingleColumnActions: visibility.usesSingleColumnActions
            ),
            actions: FloatingWidgetActionAvailability(
                canToggleDevTracking:
                    !presentation.controlActions.isDevTrackingToggleDisabled,
                canToggleMeetingMode:
                    !presentation.controlActions.isMeetingModeToggleDisabled
            )
        )
    }

    private var devTrackingToggleButton: some View {
        PrimaryActionButton(
            title: presentation.controlActions.devTrackingToggleLabel,
            systemImage: "point.3.connected.trianglepath.dotted",
            isDisabled:
                presentation.controlActions
                    .isDevTrackingToggleDisabled,
            fillsWidth: true
        ) {
            if viewModel.activityTracking.isDevTrackingRunning {
                viewModel.activityTracking.stopDevTracking()
            } else {
                viewModel.activityTracking.startDevTracking()
            }
        }
    }

    private var meetingModeToggleButton: some View {
        PrimaryActionButton(
            title: presentation.controlActions.meetingModeToggleLabel,
            systemImage: "waveform.circle",
            isDisabled:
                presentation.controlActions
                    .isMeetingModeToggleDisabled,
            fillsWidth: true
        ) {
            await toggleMeetingMode()
        }
    }

    private var openMainWindowButton: some View {
        Button {
            openWindow(id: "main")
            NSApplication.shared.activate()
        } label: {
            Label(
                presentation.quickActions.openMainWindowTitle,
                systemImage: "macwindow"
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var openDashboardButton: some View {
        Button {
            viewModel.openDashboard()
        } label: {
            Label(
                presentation.quickActions.openDashboardTitle,
                systemImage: "safari"
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func headerView(
        layoutMode: MenuBarFloatingPresentation.FloatingWidgetLayoutMode,
        isNarrowWidth: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            StatusBadge(state: presentation.recordingState, compact: true)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            if settingsStore.settings.showsElapsedTime {
                Text(presentation.recordingElapsedTimeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }

            Spacer(minLength: 2)

            if !isNarrowWidth {
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(settingsStore.settings.accentColor.color)
                .help(presentation.widgetSettingsLabel)
                .accessibilityLabel(presentation.widgetSettingsLabel)

                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!presentation.quickActions.canRefresh)
            }

            Button {
                onResizeRequest(
                    presentation.widgetSizeToggleTarget(for: layoutMode)
                )
            } label: {
                Image(
                    systemName: presentation.widgetSizeToggleIconName(
                        for: layoutMode
                    )
                )
            }
            .buttonStyle(.borderless)
            .help(presentation.widgetSizeToggleLabel(for: layoutMode))
            .accessibilityLabel(presentation.widgetSizeToggleLabel(for: layoutMode))
        }
    }

    private func toggleMeetingMode() async {
        if viewModel.meetingTranscription.state.isRunning {
            await viewModel.meetingTranscription.stop()
            return
        }
        if viewModel.meetingTranscription.canChangeAudioSource {
            viewModel.meetingTranscription.selectedAudioSource = .fullMeeting
        }
        await viewModel.meetingTranscription.start()
    }

}

private struct FloatingStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote)
    }
}

private struct FloatingWidgetActionButtonStyle: ButtonStyle {
    let accentColor: Color
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color = configuration.role == .destructive ? Color.red : accentColor
        configuration.label
            .font(font)
            .fontWeight(.medium)
            .foregroundStyle(isEnabled ? color : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(backgroundOpacity(configuration)))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(color.opacity(isEnabled ? 0.28 : 0.14), lineWidth: 1)
            }
    }

    private var font: Font {
        controlSize == .small || controlSize == .mini ? .caption : .callout
    }

    private var horizontalPadding: CGFloat {
        controlSize == .small || controlSize == .mini ? 8 : 10
    }

    private var verticalPadding: CGFloat {
        controlSize == .small || controlSize == .mini ? 4 : 6
    }

    private var minHeight: CGFloat {
        controlSize == .small || controlSize == .mini ? 24 : 30
    }

    private func backgroundOpacity(_ configuration: Configuration) -> Double {
        if !isEnabled {
            return 0.06
        }
        return configuration.isPressed ? 0.22 : 0.12
    }
}

private struct WidgetVisibility {
    let width: CGFloat
    let height: CGFloat

    init(size: CGSize) {
        self.width = size.width
        self.height = size.height
    }

    var showsCompactActivity: Bool {
        height >= 108 && height < 190
    }

    var showsDevTrackingBadge: Bool {
        height >= 135 && height < 238
    }

    var showsCurrentApp: Bool {
        height >= 190
    }

    var showsCurrentWindow: Bool {
        height >= 190
    }

    var showsOCR: Bool {
        height >= 200
    }

    var showsDevTrackingRow: Bool {
        height >= 205
    }

    var showsActiveWindowTracking: Bool {
        height >= 210
    }

    var showsDevTrackingAction: Bool {
        height >= 220
    }

    var showsMeetingModeAction: Bool {
        height >= 230
    }

    var showsOpenMainWindowAction: Bool {
        height >= 240
    }

    var showsOpenDashboardAction: Bool {
        height >= 270
    }

    var showsSecondaryActionRow: Bool {
        height >= 220
    }

    var showsQuickActionRow: Bool {
        height >= 230
    }

    var usesCondensedRecordingControl: Bool {
        width < 280 || height < 252
    }

    var usesSingleColumnActions: Bool {
        width < 360
    }

    var usesNarrowHeader: Bool {
        width <= 260
    }

    var pushesRecordingControlToBottom: Bool {
        height < 180
    }

    func contentPadding(defaultPadding: CGFloat) -> CGFloat {
        if height < 120 {
            return 6
        }
        if height < 150 {
            return 8
        }
        if height < 190 {
            return 10
        }
        return defaultPadding
    }
}

private struct FloatingDevTrackingRow: View {
    let presentation: MenuBarFloatingPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(presentation.devTrackingTitle)
                .foregroundStyle(.secondary)
            Spacer()
            DevTrackingCompactBadge(
                text: presentation.devTrackingDisplayText,
                state: presentation.devTrackingBadgeState
            )
        }
        .font(.footnote)
    }
}

private struct DevTrackingCompactBadge: View {
    let text: String
    let state: MenuBarFloatingPresentation.DevTrackingBadgeState

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .accessibilityLabel(text)
    }

    private var color: Color {
        switch state {
        case .running:
            return .green
        case .stopping:
            return .orange
        case .stopped:
            return .secondary
        case .error:
            return .red
        }
    }
}

private struct FloatingStatusBadgeRow<State: StatusPresentable>: View {
    let title: String
    let state: State

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            StatusBadge(state: state, compact: true)
                .lineLimit(1)
        }
        .font(.footnote)
    }
}
