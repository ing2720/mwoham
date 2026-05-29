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

    var body: some Scene {
        WindowGroup("MwohamMac", id: "main") {
            ContentView(viewModel: viewModel)
        }

        MenuBarExtra {
            MenuBarStatusView(viewModel: viewModel)
        } label: {
            Label("Mwoham", systemImage: "record.circle")
        }
    }
}
