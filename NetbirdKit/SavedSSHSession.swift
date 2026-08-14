//
//  SavedSSHSession.swift
//  NetbirdKit
//

import Foundation

struct SavedSSHSession: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var host: String
    var port: Int
    var user: String
}
