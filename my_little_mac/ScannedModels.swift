//
//  ScannedModels.swift
//  my_little_mac
//

import Foundation

// MARK: - RiskLevel

enum RiskLevel: Int, Codable {
    case safeToDelete = 0
    case sharedDependency = 1
    case highRisk = 2
    case unknown = 3
}

// MARK: - FileType

enum FileType: String, Codable {
    case appBundle = "App Bundle"
    case launchDaemon = "Launch Daemon"
    case launchAgent = "Launch Agent"
    case cache = "Cache"
    case preference = "Preference"
    case pkgReceipt = "PKG Receipt File"
    case hiddenDotfile = "Hidden Dotfile"
    case unknown = "Unknown"
}

// MARK: - ScannedFile

struct ScannedFile: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let size: Int64
    let fileType: FileType
    let riskLevel: RiskLevel
    let relatedBundleID: String?
    var isSelectedForDeletion: Bool
}

// MARK: - ScannedApp

struct ScannedApp: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String
    let name: String
    let mainAppUrl: URL
    var relatedFiles: [ScannedFile]
}
