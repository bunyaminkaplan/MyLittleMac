//
//  CleanerXPCService.swift
//  my_little_mac
//
//  XPC Helper Agent: Privileged Helper Tool tarafında çalışacak XPC servisi.
//  Gelen [URL] dizisini path traversal güvenlik duvarından geçirir,
//  ardından DUMMY log basarak başarı döner.
//  Fiziksel dosya silme kodu İÇERMEZ — kesinlikle YASAKLANMIŞTIR.
//

import Foundation
import os.log

// MARK: - XPC Güvenlik Hataları

enum XPCSecurityError: LocalizedError {
    case pathTraversalDetected(URL)
    case emptyURLList

    var errorDescription: String? {
        switch self {
        case .pathTraversalDetected(let url):
            return "GÜVENLİK İHLALİ: Yasaklı dizine erişim talebi reddedildi → \(url.path)"
        case .emptyURLList:
            return "Boş URL listesi gönderildi."
        }
    }
}

// MARK: - XPC Service (Privileged Helper Side)

/// Privileged Helper Tool olarak çalışacak XPC servisi.
/// `CleanerXPCProtocol`'ü implemente eder.
final class CleanerXPCService: NSObject, CleanerXPCProtocol {

    private let logger = Logger(subsystem: "com.mylittlemac.xpchelper", category: "CleanerXPCService")

    /// İzin verilen (whitelist) dizin önekleri.
    /// Sadece bu dizinlerin altındaki yollar kabul edilir.
    private let allowedPrefixes: [String] = [
        "/Library/",
        "/Applications/",
        "/usr/local/",
        "/var/folders/",
        "/private/var/folders/",
    ]

    /// Kesinlikle yasaklı dizin önekleri.
    /// Bu dizinlere yönelik talepler anında reddedilir.
    private let blockedPrefixes: [String] = [
        "/System/",
        "/usr/bin/",
        "/usr/sbin/",
        "/bin/",
        "/sbin/",
        "/private/var/db/",
        "/private/var/protected/",
    ]

    // MARK: - CleanerXPCProtocol Uygulaması

    /// DUMMY silme fonksiyonu. Fiziksel silme kodu İÇERMEZ.
    /// Gelen URL'leri güvenlik duvarından geçirir, konsola loglar ve başarılı döner.
    func removeFiles(at urls: [URL], withReply reply: @escaping (Bool, Error?) -> Void) {

        // Boş liste kontrolü
        guard !urls.isEmpty else {
            logger.warning("⚠️ Boş URL listesi alındı, işlem iptal.")
            reply(false, XPCSecurityError.emptyURLList)
            return
        }

        logger.info("📥 XPC talebi alındı: \(urls.count) dosya işlenecek.")

        // ── Path Traversal Güvenlik Duvarı ──
        for url in urls {
            do {
                try validatePath(url)
            } catch {
                logger.error("🛑 GÜVENLİK İHLALİ — talep reddedildi: \(url.path)")
                reply(false, error)
                return
            }
        }

        // ── DUMMY: Silme Simülasyonu (Sadece Log) ──
        for url in urls {
            // ⛔ GERÇEK SİLME KODU BURAYA YAZILAMAZ ⛔
            // try FileManager.default.removeItem(at:) → YASAK
            logger.info("🗑️ [DUMMY] Silinecek dosya: \(url.path)")
        }

        logger.info("✅ [DUMMY] \(urls.count) dosya başarıyla işlendi (simülasyon).")
        reply(true, nil)
    }

    // MARK: - Path Traversal Güvenlik Duvarı

    /// Gelen URL'nin izin verilen dizinlerden birinde olup olmadığını,
    /// ve yasaklı sistem dizinlerine işaret edip etmediğini kontrol eder.
    private func validatePath(_ url: URL) throws {
        let path = url.standardizedFileURL.path

        // 1) Yasaklı dizin kontrolü (blocklist)
        for blocked in blockedPrefixes {
            if path.hasPrefix(blocked) {
                throw XPCSecurityError.pathTraversalDetected(url)
            }
        }

        // 2) Kullanıcı Library dizini kontrolü (~/ ile başlayanlar)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let userLibrary = homeDir + "/Library/"
        if path.hasPrefix(userLibrary) {
            // ~/Library/ altı → izinli
            return
        }

        // 3) Whitelist kontrolü — izin verilen öneklerden birinde mi?
        let isAllowed = allowedPrefixes.contains { path.hasPrefix($0) }
        if !isAllowed {
            throw XPCSecurityError.pathTraversalDetected(url)
        }
    }
}
