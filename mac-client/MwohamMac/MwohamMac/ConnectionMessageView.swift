//
//  ConnectionMessageView.swift
//  MwohamMac
//

import SwiftUI

struct ConnectionMessageView: View {
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("로컬 백엔드 상태")
                .font(.title2)
                .fontWeight(.semibold)

            Label(
                isConnected ? "백엔드 연결됨" : "백엔드 연결 실패",
                systemImage: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(isConnected ? .green : .red)

            if !isConnected {
                Text("로컬 서버가 실행 중인지 확인해 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
