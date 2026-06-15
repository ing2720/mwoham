//
//  ConnectionMessageView.swift
//  MwohamMac
//

import SwiftUI

struct ConnectionMessageView: View {
    let state: ConnectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("로컬 백엔드 상태")
                .font(.title2)
                .fontWeight(.semibold)

            Label(
                state.label,
                systemImage: state.systemImage
            )
            .foregroundStyle(state.isError ? .red : .green)

            if state.isError {
                Text("로컬 서버가 실행 중인지 확인해 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
