//
//  CleanerXPCService.swift
//  my_little_mac
//
//  XPC Privileged Helper Architecture: Privileged Helper Tool tarafında çalışan XPC servisi.
//  Gelen [String] dosya yolu dizisini güvenlik denetiminden (Path Traversal & Whitelist) geçirir.
//  Tahribat Engeli: Fiziksel silme kodu İÇERMEZ — sadece log basıp mock başarı döner.
//

import Foundation
import os.log

// MARK: - XPC Güvenlik Hataları

enum XPCSecurityError: LocalizedError {
    case pathTraversalDetected(String)
    case emptyPathList
    case unauthorizedPath(String)
    case criticalSystemPathBlocked(String)

    var errorDescription: String? {
        switch self {
        case .pathTraversalDetected(let path):
            return "GÜVENLİK İHLALİ: Dizin aşma (path traversal) girişimi tespit edildi → \(path)"
        case .emptyPathList:
            return "Boş dosya yolu listesi gönderildi."
        case .unauthorizedPath(let path):
            return "GÜVENLİK İHLALİ: İzin verilen dizin sınırları dışında kalan yol → \(path)"
        case .criticalSystemPathBlocked(let path):
            return "GÜVENLİK İHLALİ: Kritik sistem dizinine erişim talebi reddedildi → \(path)"
        }
    }
}

// MARK: - CleanerXPCService

/// Privileged Helper Tool olarak çalışan ve CleanerXPCProtocol'ü uygulayan servis.
final class CleanerXPCService: NSObject, CleanerXPCProtocol, NSXPCListenerDelegate {

    private let logger = Logger(subsystem: "bunyamin.my-little-mac.helper", category: "CleanerXPCService")

    /// İzin verilen (whitelist) dizin önekleri.
    private let allowedPrefixes: [String] = [
        "/Library/",
        "/Applications/",
        "/usr/local/",
        "/var/folders/",
        "/private/var/folders/",
    ]

    /// Kesinlikle yasaklı sistem dizin önekleri (blocklist).
    private let blockedPrefixes: [String] = [
        "/System/",
        "/usr/bin/",
        "/usr/sbin/",
        "/bin/",
        "/sbin/",
        "/private/var/db/",
        "/private/var/protected/",
        "/etc/",
        "/var/root/",
        "/Volumes/",
    ]

    // MARK: - CleanerXPCProtocol

    /// Gelen mutlak dosya yollarını güvenlik duvarından geçirir, loglar ve mock başarı döner.
    /// ⛔ Fiziksel dosya silme komutları IPC bağlantısının stabilitesi kanıtlanana kadar kapalıdır.
    func verifyAndPrepareDeletion(paths: [String], withReply reply: @escaping (Bool, Error?) -> Void) {
        // 1. Boş liste kontrolü
        guard !paths.isEmpty else {
            logger.warning("⚠️ Boş dosya yolu listesi alındı, işlem reddedildi.")
            reply(false, XPCSecurityError.emptyPathList)
            return
        }

        logger.info("📥 XPC talebi alındı: \(paths.count) dosya yolu doğrulanacak.")

        // 2. Güvenlik ve Yol Doğrulaması (Path Traversal & Whitelist)
        for rawPath in paths {
            do {
                try validatePath(rawPath)
            } catch {
                logger.error("🛑 GÜVENLİK İHLALİ — talep reddedildi: \(rawPath, privacy: .public)")
                reply(false, error)
                return
            }
        }

        // 3. Tahribat Engeli (Mutlak Kısıtlama: Yalnızca Log & Mock Reply)
        // ⛔ GERÇEK SİLME KODU (rm -rf, removeItem(at:) vb.) KESİNLİKLE BURAYA YAZILMAZ ⛔
        for path in paths {
            logger.info("🗑️ [MOCK] Silinmesi doğrulanmış ve hazırlanan yol: \(path, privacy: .public)")
            print("[CleanerXPCService] [MOCK] verifyAndPrepareDeletion: \(path)")
        }

        logger.info("✅ [MOCK] \(paths.count) dosya yolu başarıyla doğrulandı ve simüle edildi.")
        reply(true, nil)
    }

    // MARK: - Güvenlik Duvarı

    /// Yolun güvenli olup olmadığını, traversal içermediğini ve kritik sistem dizini olmadığını doğrular.
    private func validatePath(_ rawPath: String) throws {
        // Boş yol kontrolü
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XPCSecurityError.emptyPathList
        }

        // Path Traversal kontrolü (".." karakterleri)
        if rawPath.contains("..") {
            throw XPCSecurityError.pathTraversalDetected(rawPath)
        }

        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        // Kök dizin silme koruması
        if standardized == "/" || standardized == "/Users" || standardized == "/Library" || standardized == "/Applications" {
            throw XPCSecurityError.criticalSystemPathBlocked(standardized)
        }

        // Yasaklı sistem dizinleri kontrolü (blocklist)
        for blocked in blockedPrefixes {
            if standardized == blocked || standardized.hasPrefix(blocked) {
                throw XPCSecurityError.criticalSystemPathBlocked(standardized)
            }
        }

        // Kullanıcı Library dizini (~/Library/ -> /Users/<name>/Library/)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let userLibrary = homeDir + "/Library/"
        if standardized.hasPrefix(userLibrary) {
            return
        }

        // Kullanıcı ana dizini altındaki dotfiles veya app container'ları
        if standardized.hasPrefix(homeDir + "/.") || standardized.hasPrefix(homeDir + "/Library") {
            return
        }

        // Genel Whitelist kontrolü
        let isAllowed = allowedPrefixes.contains { standardized.hasPrefix($0) }
        if !isAllowed {
            throw XPCSecurityError.unauthorizedPath(standardized)
        }
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CleanerXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
}
