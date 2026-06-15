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

            StatusBadge(state: state)

            if state.isError {
                ErrorBanner(
                    message: "로컬 서버가 실행 중인지 확인해 주세요.",
                    title: "백엔드 연결 실패"
                )
            }
        }
    }
}
