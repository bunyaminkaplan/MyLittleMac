//
//  XPCConnectionManager.swift
//  my_little_mac
//
//  XPC Privileged Helper Architecture: Ana uygulama tarafında çalışan XPC bağlantı yöneticisi.
//  macOS 13+ SMAppService.daemon(plistName:) ile modern privileged helper yönetimi,
//  NSXPCConnection IPC bağlantısı, invalidation/interruption temizliği ve
//  verifyAndPrepareDeletion köprü çağrısı.
//  Fiziksel dosya silme kodu İÇERMEZ.
//

import Foundation
import ServiceManagement
import os.log

// MARK: - XPC Bağlantı Hataları

enum XPCConnectionError: LocalizedError {
    case connectionInvalidated
    case connectionInterrupted
    case proxyUnavailable
    case daemonInstallationFailed(Error)
    case daemonUninstallationFailed(Error)
    case daemonNotFound(String)
    case requiresApproval

    var errorDescription: String? {
        switch self {
        case .connectionInvalidated:
            return "XPC bağlantısı geçersiz kılındı (invalidated)."
        case .connectionInterrupted:
            return "XPC bağlantısı kesintiye uğradı (interrupted)."
        case .proxyUnavailable:
            return "XPC proxy nesnesi alınamadı."
        case .daemonInstallationFailed(let error):
            return "SMAppService daemon kurulumu/kaydı başarısız: \(error.localizedDescription)"
        case .daemonUninstallationFailed(let error):
            return "SMAppService daemon kaldırma işlemi başarısız: \(error.localizedDescription)"
        case .daemonNotFound(let plistName):
            return "SMAppService daemon plist dosyası bulunamadı: \(plistName). Contents/Library/LaunchDaemons/ dizinini kontrol edin."
        case .requiresApproval:
            return "Privileged Helper servisi macOS kullanıcı onayı bekliyor (.requiresApproval). Lütfen Sistem Ayarları > Giriş Öğeleri panelinden izin verin."
        }
    }
}

// MARK: - XPC Connection Manager

/// Ana uygulama ile Privileged Helper Tool arasındaki XPC bağlantısını yönetir.
/// macOS 13+ `SMAppService.daemon(plistName:)` mimarisini kullanır (eski SMJobBless reddedilmiştir).
final class XPCConnectionManager {

    /// Helper Tool'un Mach servis adı (Ana uygulama bundle ID'si ile uyumlu).
    let machServiceName: String

    /// Daemon launchd plist dosya adı.
    let daemonPlistName: String

    private var connection: NSXPCConnection?
    private let logger = Logger(subsystem: "bunyamin.my-little-mac", category: "XPCConnectionManager")

    init(
        machServiceName: String = "bunyamin.my-little-mac.helper",
        daemonPlistName: String = "bunyamin.my-little-mac.helper.plist"
    ) {
        self.machServiceName = machServiceName
        self.daemonPlistName = daemonPlistName
    }

    // MARK: - Modern Yetkilendirme (SMAppService)

    /// macOS 13+ `SMAppService.daemon(plistName:)` kullanarak helper daemon'ı sisteme kaydeder.
    /// Eski `SMJobBless` yapısı tamamen reddedilmiştir.
    func installDaemon() throws {
        // SMAppService Pre-Check (Ön Doğrulama)
        let expectedPlistURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/bunyamin.my-little-mac.helper.plist")
        guard FileManager.default.fileExists(atPath: expectedPlistURL.path) else {
            os_log("DERLEME HATASI: Plist pakete dahil edilmedi", type: .error)
            logger.error("DERLEME HATASI: Plist pakete dahil edilmedi")
            print("[XPCConnectionManager] DERLEME HATASI: Plist pakete dahil edilmedi")
            throw XPCConnectionError.daemonNotFound(daemonPlistName)
        }

        let service = SMAppService.daemon(plistName: daemonPlistName)

        do {
            try service.register()
            logger.info("✅ SMAppService daemon başarıyla kaydedildi: \(self.daemonPlistName)")
        } catch {
            logger.error("🛑 SMAppService daemon kayıt hatası: \(error.localizedDescription)")
            throw XPCConnectionError.daemonInstallationFailed(error)
        }
    }

    /// Daemon'ı sistemden kaldırır.
    func uninstallDaemon() throws {
        let service = SMAppService.daemon(plistName: daemonPlistName)

        do {
            try service.unregister()
            logger.info("✅ SMAppService daemon başarıyla kaldırıldı: \(self.daemonPlistName)")
        } catch {
            logger.error("🛑 SMAppService daemon kaldırma hatası: \(error.localizedDescription)")
            throw XPCConnectionError.daemonUninstallationFailed(error)
        }
    }

    /// Manuel Servis Sıfırlama: Sadece kullanıcının UI üzerinden açıkça tetiklediği durumda
    /// eski servisi sistemden kaldırıp sıfırlar. Otomatik akışlarda asla çağrılmaz.
    func resetDaemonManually() throws {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
            logger.info("✅ SMAppService daemon kullanıcı talebiyle başarıyla sıfırlandı: \(self.daemonPlistName)")
        } catch {
            logger.error("🛑 SMAppService daemon manuel sıfırlama hatası: \(error.localizedDescription)")
            throw XPCConnectionError.daemonUninstallationFailed(error)
        }
    }

    /// Daemon'ın anlık kayıt durumunu kontrol eder.
    func daemonStatus() -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        return service.status
    }

    /// Kullanıcı onayı gerekiyorsa Sistem Ayarları > Giriş Öğeleri sayfasını açar.
    func openSystemSettingsForApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - SMAppService Kayıt Döngüsü (Registration)

    /// XPC bağlantısı kurulmadan ÖNCE daemon'ın sisteme kayıtlı olduğunu garanti eder.
    /// SMAppService.daemon(plistName: daemonPlistName) objesinin durumunu kontrol eder.
    /// Otomatik unregister çağrısı KESİNLİKLE İÇERMEZ.
    func ensureDaemonRegistered() throws {
        // SMAppService Pre-Check (Ön Doğrulama)
        let expectedPlistURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/bunyamin.my-little-mac.helper.plist")
        guard FileManager.default.fileExists(atPath: expectedPlistURL.path) else {
            os_log("DERLEME HATASI: Plist pakete dahil edilmedi", type: .error)
            logger.error("DERLEME HATASI: Plist pakete dahil edilmedi")
            print("[XPCConnectionManager] DERLEME HATASI: Plist pakete dahil edilmedi")
            throw XPCConnectionError.daemonNotFound(daemonPlistName)
        }

        let service = SMAppService.daemon(plistName: daemonPlistName)
        let status = service.status

        logger.info("🔍 SMAppService daemon kontrolü: \(self.daemonPlistName) | Durum: \(String(describing: status))")

        switch status {
        case .enabled:
            logger.info("✅ SMAppService daemon sistemde kayıtlı ve etkin (.enabled).")

        case .notRegistered, .notFound:
            logger.info("⚙️ Daemon henüz kayıtlı değil (.notRegistered / .notFound). Otomatik register() çalıştırılıyor: \(self.daemonPlistName)")
            do {
                try service.register()
                logger.info("✅ SMAppService daemon register() başarıyla çağrıldı: \(self.daemonPlistName)")
            } catch {
                let errorMsg = "🛑 SMAppService daemon kayıt başarısız oldu: \(error.localizedDescription)"
                logger.error("\(errorMsg, privacy: .public)")
                print("[XPCConnectionManager] \(errorMsg)")
                throw XPCConnectionError.daemonInstallationFailed(error)
            }

            let postRegisterStatus = service.status
            logger.info("🔍 Kayıt sonrası güncel durum: \(String(describing: postRegisterStatus))")

            if postRegisterStatus == .requiresApproval {
                let warningMsg = "⚠️ SMAppService daemon kullanıcı onayı bekliyor (.requiresApproval). Sistem Ayarları açılıyor."
                logger.warning("\(warningMsg, privacy: .public)")
                print("[XPCConnectionManager] \(warningMsg)")
                openSystemSettingsForApproval()
                throw XPCConnectionError.requiresApproval
            }

        case .requiresApproval:
            let warningMsg = "⚠️ SMAppService daemon kullanıcı onayı bekliyor (.requiresApproval). Sistem Ayarları açılıyor ve bağlantı kurulmadan dönülüyor."
            logger.warning("\(warningMsg, privacy: .public)")
            print("[XPCConnectionManager] \(warningMsg)")
            openSystemSettingsForApproval()
            throw XPCConnectionError.requiresApproval

        @unknown default:
            logger.warning("⚠️ Bilinmeyen SMAppService durumu: \(String(describing: status))")
            throw XPCConnectionError.proxyUnavailable
        }
    }

    /// SMAppService gereksinimi olan Contents/Library/LaunchDaemons/<plistName> yolunu garantiye alır.
    private func prepareLaunchDaemonPlistIfNeeded() {
        let launchDaemonsDir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons")
        let targetURL = launchDaemonsDir.appendingPathComponent(daemonPlistName)

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.createDirectory(at: launchDaemonsDir, withIntermediateDirectories: true)
            if let resourceURL = Bundle.main.url(forResource: "bunyamin.my-little-mac.helper", withExtension: "plist") {
                try? FileManager.default.copyItem(at: resourceURL, to: targetURL)
            }
        }
    }

    // MARK: - XPC Bağlantısı

    /// XPC bağlantısını oluşturur veya mevcut bağlantıyı döner.
    /// Asenkron Bağlantı Engeli ve Durum Yönetimi:
    /// - Durum .enabled ise XPC bağlantısını başlatır.
    /// - Durum .notRegistered veya .notFound ise try ensureDaemonRegistered() üzerinden register() çağırır.
    /// - Durum .requiresApproval ise SMAppService.openSystemSettingsLoginItems() çağırır ve fonksiyondan bağlantıyı kurmadan döner (throw).
    private func establishConnection() throws -> NSXPCConnection {
        if let existing = connection {
            return existing
        }

        // 1. Bağlantı öncesi daemon kayıt kontrolü ve kaydı (Registration Rutini)
        try ensureDaemonRegistered()

        // 2. Onay Yönlendirmesi ve Bağlantı Akışı:
        let service = SMAppService.daemon(plistName: daemonPlistName)
        let currentStatus = service.status

        switch currentStatus {
        case .enabled:
            logger.info("✅ SMAppService daemon .enabled durumunda. XPC bağlantısı başlatılıyor.")

        case .requiresApproval:
            let msg = "⚠️ XPC bağlantısı kurulmadı: Daemon kullanıcı onayı bekliyor (.requiresApproval). Sistem Ayarları açılıyor."
            logger.warning("\(msg, privacy: .public)")
            print("[XPCConnectionManager] \(msg)")
            openSystemSettingsForApproval()
            throw XPCConnectionError.requiresApproval

        case .notRegistered, .notFound:
            let msg = "🛑 XPC bağlantısı kurulamadı: Daemon henüz etkin değil (Durum: \(String(describing: currentStatus)))."
            logger.error("\(msg, privacy: .public)")
            print("[XPCConnectionManager] \(msg)")
            throw XPCConnectionError.proxyUnavailable

        @unknown default:
            throw XPCConnectionError.proxyUnavailable
        }

        // 3. NSXPCConnection oluştur (options KESİNLİKLE .privileged)
        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: CleanerXPCProtocol.self)

        // Invalidation Handler
        newConnection.invalidationHandler = { [weak self] in
            let msg = "⚠️ XPC bağlantısı geçersiz kılındı (invalidated). Helper servisi sonlandırılmış veya izin verilmemiş olabilir."
            self?.logger.warning("\(msg, privacy: .public)")
            print("[XPCConnectionManager] \(msg)")
            self?.connection = nil
        }

        // Interruption Handler
        newConnection.interruptionHandler = { [weak self] in
            let msg = "⚠️ XPC bağlantısı kesintiye uğradı (interrupted). Helper yeniden başlatılıyor olabilir."
            self?.logger.warning("\(msg, privacy: .public)")
            print("[XPCConnectionManager] \(msg)")
            self?.connection = nil
        }

        newConnection.resume()
        connection = newConnection

        logger.info("✅ XPC bağlantısı kuruldu (options: .privileged): \(self.machServiceName)")
        return newConnection
    }

    // MARK: - IPC Doğrulama ve Hazırlık Talebi

    /// UI ve İletişim Bariyeri üzerinden filtrelenmiş mutlak dosya yollarını (`[String]`)
    /// hedef uygulamanın bundleID bilgisiyle birlikte Privileged Helper Tool'a iletir.
    /// - Parameters:
    ///   - bundleID: Hedef uygulamanın CFBundleIdentifier değeri.
    ///   - paths: UI tarafından filtrelenmiş ve onaylanmış mutlak fiziksel dosya yolları.
    /// - Returns: Helper işlemi onayladığında `true`.
    func verifyAndPrepareDeletion(bundleID: String, paths: [String]) async throws -> Bool {
        // establishConnection daemon kaydını doğrular ve başarısızsa bağlantıyı başlatmadan throw eder
        let xpcConnection = try establishConnection()

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = xpcConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                let nsError = error as NSError
                let detailedError = """
                🛑 [XPC PROXY ERROR]
                - Description: \(error.localizedDescription)
                - Domain: \(nsError.domain)
                - Code: \(nsError.code)
                - UserInfo: \(nsError.userInfo)
                - Full Error Object: \(String(describing: error))
                """
                self?.logger.error("🛑 XPC remoteObjectProxyWithErrorHandler tetiklendi:\n\(detailedError, privacy: .public)")
                print(detailedError)
                self?.connection = nil
                continuation.resume(throwing: error)
            }) as? CleanerXPCProtocol else {
                let unavailableMsg = "🛑 [XPC PROXY UNAVAILABLE] XPC remoteObjectProxy nesnesi CleanerXPCProtocol protokolüne cast edilemedi veya helper yanıt vermiyor."
                self.logger.error("\(unavailableMsg, privacy: .public)")
                print(unavailableMsg)
                self.connection = nil
                continuation.resume(throwing: XPCConnectionError.proxyUnavailable)
                return
            }

            proxy.verifyAndPrepareDeletion(bundleID: bundleID, paths: paths) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    // MARK: - Bağlantı Temizliği

    /// Mevcut XPC bağlantısını kapatır ve kaynakları serbest bırakır.
    func disconnect() {
        connection?.invalidate()
        connection = nil
        logger.info("🔌 XPC bağlantısı kapatıldı.")
    }
}
