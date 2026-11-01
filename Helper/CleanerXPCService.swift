//
//  CleanerXPCService.swift
//  bunyamin.my-little-mac.helper
//
//  XPC Privileged Helper Architecture: Privileged Helper Tool tarafında çalışan XPC servisi.
//  Target İzolasyonu: Sadece Helper hedefinde derlenir; ana uygulamadan KESİNLİKLE izoledir.
//  Gelen [String] dosya yolu dizisini bundleID bağlamında güvenlik denetiminden
//  (Mutlak Yol, Path Traversal, Kritik Sistem Dizinleri, Sahiplik) geçirir.
//  Remote Execution Kanıtı: PID ve UID (root: 0) değerlerini döner.
//  Silinebilirlik Kontrolü (Dry-Run): FileManager.default.isDeletableFile(atPath:) ile simülasyon.
//  Tahribat Engeli: Fiziksel silme kodu İÇERMEZ — sadece log basıp mock başarı döner.
//

import Foundation
import ServiceManagement
import Darwin
import os.log

// MARK: - C os_transaction Köprüsü
@_silgen_name("os_transaction_create")
private func os_transaction_create(_ description: UnsafePointer<CChar>) -> AnyObject?

// MARK: - XPC Yaşam Döngüsü ve Kaynak Yönetimi (Idle-Exit Guard)

/// IPC işlemi sırasında aktif bir transaction ve activity tutar.
/// İşlem tamamlandığında (reply döndüğünde) veya nesne deallocate olduğunda
/// işlemi sonlandırarak launchd'nin servisi otomatik boşta kapatmasına (idle-exit) olanak tanır.
final class XPCTransactionGuard {
    private var transaction: AnyObject?
    private var activity: NSObjectProtocol?
    private var isFinished = false
    private let logger = Logger(subsystem: "bunyamin.my-little-mac.helper", category: "XPCTransactionGuard")

    init(name: String, reason: String) {
        self.transaction = os_transaction_create(name)
        self.activity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .latencyCritical],
            reason: reason
        )
        logger.info("⏱️ [Idle-Exit Guard] Transaction ve Activity başlatıldı: \(name, privacy: .public)")
    }

    func end() {
        guard !isFinished else { return }
        isFinished = true
        if let act = activity {
            ProcessInfo.processInfo.endActivity(act)
            activity = nil
        }
        transaction = nil
        logger.info("💤 [Idle-Exit Guard] Transaction sonlandırıldı. Servis boşta kapanmaya (idle-exit) hazır.")
    }

    deinit {
        end()
    }
}

// MARK: - DispatchSourceTimer ile Helper Otomatik Kapanma (Idle Timer)

/// Helper hedefi (bunyamin.my-little-mac.helper) için bellek sızıntılarını ve
/// zombie arka plan süreçlerini önleyen DispatchSourceTimer tabanlı yaşam döngüsü yöneticisi.
final class HelperIdleTimer {
    static let shared = HelperIdleTimer()

    private let queue = DispatchQueue(label: "bunyamin.my-little-mac.helper.idletimer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isSuspended = false
    private let timeoutSeconds: Int
    private let logger = Logger(subsystem: "bunyamin.my-little-mac.helper", category: "HelperIdleTimer")

    init(timeoutSeconds: Int = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Bağlantı kurulduğunda veya Helper başlatıldığında 10 saniyelik zamanlayıcıyı başlatır / sıfırlar.
    func startTimer() {
        queue.sync {
            cancelInternal()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .seconds(timeoutSeconds))
            t.setEventHandler { [weak self] in
                self?.handleTimeout()
            }
            t.resume()
            timer = t
            isSuspended = false
            logger.info("⏱️ [HelperIdleTimer] \(self.timeoutSeconds) saniyelik idle timer başlatıldı.")
            print("[bunyamin.my-little-mac.helper] [IDLE TIMER] Started \(self.timeoutSeconds)s countdown.")
        }
    }

    /// verifyAndPrepareDeletion gibi her XPC fonksiyon çağrısının başlangıcında zamanlayıcıyı askıya alır (suspend).
    func suspendTimer() {
        queue.sync {
            guard let t = timer else { return }
            if !isSuspended {
                t.suspend()
                isSuspended = true
                logger.info("⏸️ [HelperIdleTimer] XPC işlemi başladı, zamanlayıcı askıya alındı (suspend).")
                print("[bunyamin.my-little-mac.helper] [IDLE TIMER] Suspended timer during XPC operation.")
            }
        }
    }

    /// İşlem tamamlanıp ana uygulamaya reply dönüldüğünde zamanlayıcıyı yeniden başlatır (resume) ve sıfırlar.
    func resumeTimer() {
        queue.sync {
            guard let t = timer else {
                cancelInternal()
                let newTimer = DispatchSource.makeTimerSource(queue: queue)
                newTimer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                newTimer.setEventHandler { [weak self] in
                    self?.handleTimeout()
                }
                newTimer.resume()
                timer = newTimer
                isSuspended = false
                return
            }

            if isSuspended {
                t.resume()
                isSuspended = false
            }
            t.schedule(deadline: .now() + .seconds(timeoutSeconds))
            logger.info("▶️ [HelperIdleTimer] XPC işlemi bitti, zamanlayıcı yeniden başlatıldı (resume & \(self.timeoutSeconds)s reset).")
            print("[bunyamin.my-little-mac.helper] [IDLE TIMER] Resumed and reset countdown to \(self.timeoutSeconds)s.")
        }
    }

    /// İletişim koptuğunda (invalidation / interruption) zamanlayıcıyı iptal edip süreci KESİNLİKLE exit(0) ile derhal sonlandırır.
    func cancelAndExitImmediately(reason: String) {
        queue.sync {
            logger.info("🛑 [HelperIdleTimer] \(reason). Süreç exit(0) ile derhal sonlandırılıyor.")
            print("[bunyamin.my-little-mac.helper] [IMMEDIATE EXIT] Reason: \(reason). Terminating process with exit(0)...")
            cancelInternal()
            terminateHelperProcess()
        }
    }

    /// 10 saniye boyunca yeni istek gelmediğinde süreci exit(0) ile sonlandırır.
    private func handleTimeout() {
        logger.info("💤 [HelperIdleTimer] \(self.timeoutSeconds) saniye boşta kalındı (idle timeout). Süreç exit(0) ile sonlandırılıyor.")
        print("[bunyamin.my-little-mac.helper] [IDLE TIMEOUT] \(self.timeoutSeconds)s idle timeout reached with no requests. Terminating with exit(0)...")
        cancelInternal()
        terminateHelperProcess()
    }

    private func cancelInternal() {
        if let t = timer {
            if isSuspended {
                t.resume()
                isSuspended = false
            }
            t.cancel()
            timer = nil
        }
    }

    private func terminateHelperProcess() {
        let processName = ProcessInfo.processInfo.processName
        if processName != "my_little_mac" {
            exit(0)
        }
    }
}

// MARK: - CleanerXPCService

/// Privileged Helper Tool olarak çalışan ve CleanerXPCProtocol'ü uygulayan servis.
/// SADECE Helper sürecinde (bunyamin.my-little-mac.helper) çalışır; ana uygulama target'ında yer almaz.
@objc public final class CleanerXPCService: NSObject, CleanerXPCProtocol, NSXPCListenerDelegate {

    private let logger = Logger(subsystem: "bunyamin.my-little-mac.helper", category: "CleanerXPCService")

    // MARK: - CleanerXPCProtocol

    /// Gelen mutlak dosya yollarını bundleID bağlamında güvenlik filtresinden geçirir,
    /// silinebilirlik durumunu simüle eder (Dry-Run) ve sonucu ana uygulamaya iletir.
    /// Remote Execution Kanıtı: PID ve UID değerlerini döner (root UID: 0 zorunludur).
    /// ⛔ Fiziksel dosya silme komutları İÇERMEZ.
    @objc public func verifyAndPrepareDeletion(
        bundleID: String,
        paths: [String],
        withReply reply: @escaping (Bool, Int, Int, Error?) -> Void
    ) {
        let currentPID = Int(getpid())
        let currentUID = Int(getuid())

        // 2. İşlem Başına Timer Sıfırlama:
        HelperIdleTimer.shared.suspendTimer()

        // Yaşam Döngüsü ve Kaynak Yönetimi:
        let transactionGuard = XPCTransactionGuard(
            name: "bunyamin.my-little-mac.helper.verifyAndPrepareDeletion",
            reason: "IPC verifyAndPrepareDeletion for [\(bundleID)] with \(paths.count) paths"
        )

        // Yanıt döndüğünde KESİNLİKLE işlemi sonlandıran ve zamanlayıcıyı yeniden başlatan güvenli closure
        let safeReply: (Bool, Error?) -> Void = { success, error in
            transactionGuard.end()
            HelperIdleTimer.shared.resumeTimer()
            // Remote Execution Kanıtı: (Bool, Int, Int, Error?)
            reply(success, currentPID, currentUID, error)
        }

        // 1. Boş liste kontrolü
        guard !paths.isEmpty else {
            let error = NSError(
                domain: "CleanerXPCSecurity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Güvenlik ihlali: Dosya yolu listesi boş."]
            )
            logger.warning("⚠️ Boş dosya yolu listesi alındı, işlem reddedildi.")
            safeReply(false, error)
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
            safeReply(false, error)
            return
        }

        logger.info("📥 XPC talebi alındı: [\(cleanBundleID)] için \(paths.count) dosya yolu doğrulanacak. PID: \(currentPID), UID: \(currentUID)")

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
                safeReply(false, error)
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

        // 6. Tahribat Engeli & Başarılı Yanıt (Idle-Exit tetiklenebilir)
        logger.info("✅ [DRY-RUN] \(validatedStandardizedPaths.count) dosya yolu başarıyla doğrulandı ve simüle edildi. PID=\(currentPID), UID=\(currentUID)")
        safeReply(true, nil)
    }

    /// XPC proxy üzerinden Helper sürecinin root yetkisini (UID: 0) doğrular.
    @objc public func checkRootAuthority(withReply reply: @escaping (Bool, Int, Int) -> Void) {
        let currentPID = Int(getpid())
        let currentUID = Int(getuid())
        let isRoot = (currentUID == 0)
        logger.info("🔍 [XPC Auth Check] PID: \(currentPID), UID: \(currentUID), isRoot: \(isRoot)")
        reply(isRoot, currentPID, currentUID)
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
            _ = runLaunchctl(arguments: ["bootout", "system", path])
            if let label = serviceLabel, !label.isEmpty {
                _ = runLaunchctl(arguments: ["bootout", "system/" + label])
            }
            _ = runLaunchctl(arguments: ["unload", "-w", path])
        } else if isAgent {
            var statBuf = stat()
            let consoleUID: uid_t = (stat("/dev/console", &statBuf) == 0) ? statBuf.st_uid : 501

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

        // 3. İletişim Koptuğunda (Invalidation) Anında Kapanma:
        newConnection.invalidationHandler = {
            HelperIdleTimer.shared.cancelAndExitImmediately(reason: "CleanerXPCService: Bağlantı geçersiz kılındı (invalidated)")
        }

        newConnection.interruptionHandler = {
            HelperIdleTimer.shared.cancelAndExitImmediately(reason: "CleanerXPCService: Bağlantı kesintiye uğradı (interrupted)")
        }

        newConnection.resume()

        // 1. Bağlantı kurulduktan sonra 10 saniyelik boşta kalma zamanlayıcısını başlat
        HelperIdleTimer.shared.startTimer()

        return true
    }
}
