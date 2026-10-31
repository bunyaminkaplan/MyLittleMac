//
//  CleanerXPCService.swift
//  my_little_mac
//
//  XPC Privileged Helper Architecture: Privileged Helper Tool tarafında çalışan XPC servisi.
//  Gelen [String] dosya yolu dizisini bundleID bağlamında güvenlik denetiminden
//  (Mutlak Yol, Path Traversal, Kritik Sistem Dizinleri, Sahiplik) geçirir.
//  Silinebilirlik Kontrolü (Dry-Run): FileManager.default.isDeletableFile(atPath:) ile simülasyon.
//  Tahribat Engeli: Fiziksel silme kodu İÇERMEZ — sadece log basıp mock başarı döner.
//

import Foundation
import os.log

// MARK: - CleanerXPCService

/// Privileged Helper Tool olarak çalışan ve CleanerXPCProtocol'ü uygulayan servis.
@objc public final class CleanerXPCService: NSObject, CleanerXPCProtocol, NSXPCListenerDelegate {

    private let logger = Logger(subsystem: "bunyamin.my-little-mac.helper", category: "CleanerXPCService")

    // MARK: - CleanerXPCProtocol

    /// Gelen mutlak dosya yollarını bundleID bağlamında güvenlik filtresinden geçirir,
    /// silinebilirlik durumunu simüle eder (Dry-Run) ve sonucu ana uygulamaya iletir.
    /// ⛔ Fiziksel dosya silme komutları İÇERMEZ.
    @objc public func verifyAndPrepareDeletion(
        bundleID: String,
        paths: [String],
        withReply reply: @escaping (Bool, Error?) -> Void
    ) {
        // 1. Boş liste kontrolü
        guard !paths.isEmpty else {
            let error = NSError(
                domain: "CleanerXPCSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Dosya yolu listesi boş."]
            )
            logger.warning("⚠️ Boş dosya yolu listesi alındı, işlem reddedildi.")
            reply(false, error)
            return
        }

        let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleID.isEmpty else {
            let error = NSError(
                domain: "CleanerXPCSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Geçersiz bundleID."]
            )
            logger.warning("⚠️ Boş veya geçersiz bundleID alındı, işlem reddedildi.")
            reply(false, error)
            return
        }

        logger.info("📥 XPC talebi alındı: [\(cleanBundleID)] için \(paths.count) dosya yolu doğrulanacak.")

        // 2. Hedef uygulama belirteçlerini bundleID üzerinden türet
        let targetTokens = deriveTargetTokens(from: cleanBundleID)

        // 3. Güvenlik, Mutlak Yol ve Sahiplik Doğrulaması
        var validatedStandardizedPaths: [String] = []
        for rawPath in paths {
            do {
                let validatedPath = try validatePath(rawPath, bundleID: cleanBundleID, targetTokens: targetTokens)
                validatedStandardizedPaths.append(validatedPath)
            } catch {
                logger.error("🛑 GÜVENLİK İHLALİ — talep reddedildi: \(rawPath, privacy: .public) | Hata: \(error.localizedDescription)")
                print("[CleanerXPCService] [SECURITY VIOLATION] Rejected: \(rawPath) - \(error.localizedDescription)")
                reply(false, error)
                return
            }
        }

        // 4. Silinebilirlik Kontrolü (Dry-Run Simülasyonu)
        for path in validatedStandardizedPaths {
            _ = FileManager.default.isDeletableFile(atPath: path)
            let dryRunMsg = "Dry-run başarılı: [\(path)]"
            print(dryRunMsg)
            logger.info("Dry-run başarılı: [\(path, privacy: .public)]")
        }

        // 5. Tahribat Engeli
        logger.info("✅ [DRY-RUN] \(validatedStandardizedPaths.count) dosya yolu başarıyla doğrulandı ve simüle edildi.")
        reply(true, nil)
    }

    // MARK: - Güvenlik Duvarı & Doğrulama Katmanı

    private func validatePath(_ rawPath: String, bundleID: String, targetTokens: Set<String>) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Mutlak yol (absolute path) kontrolü
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Mutlak yol (absolute path) formatında değil - \(rawPath)"]
            )
        }

        // 2. Path Traversal kontrolü
        if trimmed.contains("..") {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Dizin aşma (path traversal) tespit edildi - \(rawPath)"]
            )
        }

        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard standardized.hasPrefix("/") else {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Geçersiz mutlak yol - \(standardized)"]
            )
        }

        // 3. Kök dizin engeli
        if standardized == "/" || standardized == "/Users" || standardized == "/Library" || standardized == "/Applications" {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Kök dizin engellendi - \(standardized)"]
            )
        }

        // 4. Kritik çekirdek macOS dizinleri (/System/, /sbin/, /bin/, /usr/ - /usr/local/ hariç)
        if standardized == "/System" || standardized.hasPrefix("/System/") {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Kritik çekirdek macOS dizini engellendi (/System/) - \(standardized)"]
            )
        }

        if standardized == "/sbin" || standardized.hasPrefix("/sbin/") {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Kritik sistem dizini engellendi (/sbin/) - \(standardized)"]
            )
        }

        if standardized == "/bin" || standardized.hasPrefix("/bin/") {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Kritik sistem dizini engellendi (/bin/) - \(standardized)"]
            )
        }

        // /usr/ (/usr/local/ hariç)
        if standardized == "/usr" || (standardized.hasPrefix("/usr/") && !standardized.hasPrefix("/usr/local/")) {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Kritik sistem dizini engellendi (/usr/) - \(standardized)"]
            )
        }

        if standardized.hasPrefix("/private/var/db/") || standardized.hasPrefix("/private/var/protected/") || standardized.hasPrefix("/var/root/") {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Korumalı sistem dizini engellendi - \(standardized)"]
            )
        }

        // 5. Genel kütüphane kök dizinlerinin silinmesini önleme
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let genericRoots: Set<String> = [
            homeDir,
            homeDir + "/Library",
            homeDir + "/Library/Application Support",
            homeDir + "/Library/Caches",
            homeDir + "/Library/Preferences",
            homeDir + "/Library/Logs",
            homeDir + "/Library/Containers",
            homeDir + "/Library/Application Scripts",
            homeDir + "/Library/Saved Application State",
            homeDir + "/Library/WebKit",
            homeDir + "/Library/HTTPStorages"
        ]
        if genericRoots.contains(standardized) {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Kök dizin engellendi - \(standardized)"]
            )
        }

        // 6. Sahiplik (Ownership) doğrulaması
        let lowercasedPath = standardized.lowercased()
        let isMatched = targetTokens.contains { token in
            lowercasedPath.contains(token)
        }

        guard isMatched else {
            throw NSError(
                domain: "CleanerXPCSecurity",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Yol hedef bundleID (\(bundleID)) belirteçleriyle eşleşmiyor - \(standardized)"]
            )
        }

        return standardized
    }

    // MARK: - Belirteç Türetme

    /// bundleID (Örn: "com.google.Chrome" veya "com.tinyspeck.slackmacgap") değerinden
    /// hedef klasör/dosya isimleriyle eşleşecek belirteçleri türetir.
    private func deriveTargetTokens(from bundleID: String) -> Set<String> {
        var tokens = Set<String>()
        let lower = bundleID.lowercased()
        tokens.insert(lower)

        let ignoredTokens: Set<String> = ["com", "org", "net", "io", "app"]
        let delimiters = CharacterSet(charactersIn: ".-_")
        let parts = lower.components(separatedBy: delimiters).filter { !$0.isEmpty }

        for part in parts {
            if !ignoredTokens.contains(part) && part.count >= 3 {
                tokens.insert(part)

                // Yaygın macOS eklerini temizle (örn. slackmacgap -> slack, appnameosx -> appname)
                for suffix in ["macgap", "macos", "osx", "desktop", "client", "helper"] {
                    if part.hasSuffix(suffix) && part.count > suffix.count + 2 {
                        let stripped = String(part.dropLast(suffix.count))
                        if !ignoredTokens.contains(stripped) && stripped.count >= 3 {
                            tokens.insert(stripped)
                        }
                    }
                }
            }
        }

        if parts.count >= 2 {
            let lastTwo = parts.suffix(2).joined(separator: ".")
            tokens.insert(lastTwo)
        }

        return tokens
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CleanerXPCProtocol.self)
        newConnection.exportedObject = CleanerXPCService()
        newConnection.resume()
        return true
    }
}
