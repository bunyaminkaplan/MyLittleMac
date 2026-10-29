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
    case container = "Group Container"
    case unknown = "Unknown"
}

// MARK: - DiscoveryMethod

enum DiscoveryMethod: String, Codable {
    case standard
    case teamID
    case btm
    case heuristic
    case `extension`
    case heuristicOverride
}

// MARK: - ScannedFile

struct ScannedFile: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let size: Int64
    let fileType: FileType
    let riskLevel: RiskLevel
    let relatedBundleID: String?
    let discoveryMethod: DiscoveryMethod
    let reasoningText: String?
    var isSelectedForDeletion: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        size: Int64,
        fileType: FileType,
        riskLevel: RiskLevel,
        relatedBundleID: String?,
        discoveryMethod: DiscoveryMethod = .standard,
        reasoningText: String? = nil,
        isSelectedForDeletion: Bool
    ) {
        self.id = id
        self.url = url
        self.size = size
        self.fileType = fileType
        self.riskLevel = riskLevel
        self.relatedBundleID = relatedBundleID
        self.discoveryMethod = discoveryMethod
        self.reasoningText = reasoningText
        self.isSelectedForDeletion = isSelectedForDeletion
    }
}

// MARK: - ScannedApp

struct ScannedApp: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String
    let name: String
    let mainAppUrl: URL
    var relatedFiles: [ScannedFile]
}
