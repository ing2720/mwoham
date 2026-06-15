//
//  RecordingControlsView.swift
//  MwohamMac
//

import SwiftUI

struct RecordingControlsView: View {
    @ObservedObject var viewModel: RecordingViewModel

    var body: some View {
        RecordingControl(viewModel: viewModel)
    }
}
