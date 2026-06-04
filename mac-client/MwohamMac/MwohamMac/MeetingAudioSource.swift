//
//  MeetingAudioSource.swift
//  MwohamMac
//

import Foundation

enum MeetingAudioSource: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case fullMeeting

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .microphone:
            return "마이크"
        case .systemAudio:
            return "시스템 오디오"
        case .fullMeeting:
            return "회의 전체"
        }
    }

    var primaryTranscriptSource: String {
        switch self {
        case .microphone:
            return "apple_speech_microphone"
        case .systemAudio:
            return "apple_speech_system_audio"
        case .fullMeeting:
            return "apple_speech_full_meeting"
        }
    }

    var startStatusText: String {
        switch self {
        case .microphone:
            return "회의 전사 시작 중"
        case .systemAudio:
            return "시스템 오디오 전사 시작 중"
        case .fullMeeting:
            return "회의 전체 전사 준비 중"
        }
    }

    var permissionHelpText: String {
        switch self {
        case .microphone:
            return "음성 인식과 마이크 권한을 허용한 뒤 다시 시도해 주세요."
        case .systemAudio:
            return "음성 인식과 화면 기록 권한을 허용한 뒤 다시 시도해 주세요."
        case .fullMeeting:
            return "음성 인식, 마이크, 화면 기록 권한을 허용한 뒤 다시 시도해 주세요."
        }
    }

    var guidanceText: String? {
        switch self {
        case .microphone:
            return nil
        case .systemAudio:
            return "시스템 오디오 전사에는 화면 기록 권한이 필요할 수 있습니다."
        case .fullMeeting:
            return "마이크와 시스템 오디오를 하나의 Apple Speech 전사 흐름으로 처리합니다. 원본 오디오는 저장하지 않습니다."
        }
    }

    var requiresMicrophone: Bool {
        self == .microphone || self == .fullMeeting
    }

    var requiresSystemAudio: Bool {
        self == .systemAudio || self == .fullMeeting
    }
}
