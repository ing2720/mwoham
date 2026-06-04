//
//  SpeechRecognitionErrorFormatter.swift
//  MwohamMac
//

import Foundation

enum SpeechRecognitionErrorFormatter {
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription
        return "\(nsError.domain) code \(nsError.code): \(message)"
    }
}
