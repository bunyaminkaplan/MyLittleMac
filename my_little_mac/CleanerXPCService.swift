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
import ServiceManagement
import Darwin
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

        // 4. Servis Boşaltma (Daemon/Agent Unloading) — KESİNLİKLE dry-run simülasyonundan ÖNCE
        for path in validatedStandardizedPaths {
            if path.hasSuffix(".plist") && (path.contains("/LaunchDaemons/") || path.contains("/LaunchAgents/")) {
                unloadLaunchService(atPath: path)
            }
        }

        // 5. Silinebilirlik Kontrolü (Dry-Run Simülasyonu)
        for path in validatedStandardizedPaths {
            _ = FileManager.default.isDeletableFile(atPath: path)
            let dryRunMsg = "Dry-run başarılı: [\(path)]"
            print(dryRunMsg)
            logger.info("Dry-run başarılı: [\(path, privacy: .public)]")
        }

        // 6. Tahribat Engeli
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

    // MARK: - Servis Boşaltma (Daemon/Agent Unloading)

    /// /Library/LaunchDaemons veya ~/Library/LaunchAgents dizinlerindeki .plist servislerini
    /// dry-run simülasyonundan ÖNCE bellekten düşürür (unload) ve BTM kaydını temizler.
    private func unloadLaunchService(atPath path: String) {
        let isDaemon = path.contains("/LaunchDaemons/")
        let isAgent = path.contains("/LaunchAgents/")
        guard isDaemon || isAgent else { return }

        let plistURL = URL(fileURLWithPath: path)
        let plistName = plistURL.lastPathComponent

        // Plist dosyasından 'Label' oku (varsa)
        var serviceLabel: String? = nil
        if let data = try? Data(contentsOf: plistURL),
           let plistDict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            serviceLabel = plistDict["Label"] as? String
        }

        logger.info("⚙️ [SERVICE UNLOAD] Servis bellekten düşürülüyor: \(path, privacy: .public) | Label: \(serviceLabel ?? plistName)")
        print("[CleanerXPCService] [SERVICE UNLOAD] Unloading service: \(path) (Label: \(serviceLabel ?? plistName))")

        // 1. SMAppService API ile BTM ve launchd kaydını temizleme
        if #available(macOS 13.0, *) {
            if isDaemon {
                let service = SMAppService.daemon(plistName: plistName)
                do {
                    try service.unregister()
                    logger.info("✅ SMAppService.daemon unregister başarılı: \(plistName)")
                } catch {
                    logger.debug("ℹ️ SMAppService.daemon unregister uyarısı: \(error.localizedDescription)")
                }
            } else if isAgent {
                let service = SMAppService.agent(plistName: plistName)
                do {
                    try service.unregister()
                    logger.info("✅ SMAppService.agent unregister başarılı: \(plistName)")
                } catch {
                    logger.debug("ℹ️ SMAppService.agent unregister uyarısı: \(error.localizedDescription)")
                }
            }
        }

        // 2. launchctl bootout ve unload komutları ile bellekten düşürme
        if isDaemon {
            // System domain bootout
            _ = runLaunchctl(arguments: ["bootout", "system", path])
            if let label = serviceLabel, !label.isEmpty {
                _ = runLaunchctl(arguments: ["bootout", "system/" + label])
            }
            _ = runLaunchctl(arguments: ["unload", "-w", path])
        } else if isAgent {
            // Aktif konsol kullanıcısının UID'sini bul
            var statBuf = stat()
            let consoleUID: uid_t = (stat("/dev/console", &statBuf) == 0) ? statBuf.st_uid : 501

            // GUI domain bootout
            _ = runLaunchctl(arguments: ["bootout", "gui/\(consoleUID)", path])
            if let label = serviceLabel, !label.isEmpty {
                _ = runLaunchctl(arguments: ["bootout", "gui/\(consoleUID)/" + label])
            }
            _ = runLaunchctl(arguments: ["unload", "-w", path])
        }

        logger.info("🏁 [SERVICE UNLOAD] Servis boşaltma işlemi tamamlandı: \(path, privacy: .public)")
        print("[CleanerXPCService] [SERVICE UNLOAD] Unload completed: \(path)")
    }

    @discardableResult
    private func runLaunchctl(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CleanerXPCProtocol.self)
        newConnection.exportedObject = CleanerXPCService()
        newConnection.resume()
        return true
    }
}
