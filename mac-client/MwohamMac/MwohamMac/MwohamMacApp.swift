//
//  MwohamMacApp.swift
//  MwohamMac
//
//  Created by a on 5/29/26.
//

import SwiftUI

@main
struct MwohamMacApp: App {
    @StateObject private var viewModel = BackendStatusViewModel()
    @StateObject private var floatingWidgetSettingsStore: FloatingWidgetSettingsStore
    @StateObject private var floatingWidgetController: FloatingWidgetController

    init() {
        let settingsStore = FloatingWidgetSettingsStore()
        _floatingWidgetSettingsStore = StateObject(wrappedValue: settingsStore)
        _floatingWidgetController = StateObject(
            wrappedValue: FloatingWidgetController(settingsStore: settingsStore)
        )
    }

    var body: some Scene {
        WindowGroup("MwohamMac", id: "main") {
            ContentView(viewModel: viewModel)
        }

        MenuBarExtra {
            MenuBarStatusView(
                viewModel: viewModel,
                floatingWidgetController: floatingWidgetController
            )
        } label: {
            Label(
                "Mwoham",
                systemImage: MenuBarFloatingPresentation(
                    provider: viewModel,
                    isFloatingWidgetVisible: floatingWidgetController.isVisible
                ).menuBarIconName
            )
        }
    }
}
