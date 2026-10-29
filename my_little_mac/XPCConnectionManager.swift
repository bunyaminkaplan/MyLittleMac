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

    var errorDescription: String? {
        switch self {
        case .connectionInvalidated:
            return "XPC bağlantısı geçersiz kılındı (invalidated)."
        case .connectionInterrupted:
            return "XPC bağlantısı kesintiye uğradı (interrupted)."
        case .proxyUnavailable:
            return "XPC proxy nesnesi alınamadı."
        case .daemonInstallationFailed(let error):
            return "SMAppService daemon kurulumu başarısız: \(error.localizedDescription)"
        case .daemonUninstallationFailed(let error):
            return "SMAppService daemon kaldırma işlemi başarısız: \(error.localizedDescription)"
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

    /// Daemon'ın anlık kayıt durumunu kontrol eder.
    func daemonStatus() -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        return service.status
    }

    /// Kullanıcı onayı gerekiyorsa Sistem Ayarları > Giriş Öğeleri sayfasını açar.
    func openSystemSettingsForApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC Bağlantısı

    /// XPC bağlantısını oluşturur veya mevcut bağlantıyı döner.
    private func establishConnection() -> NSXPCConnection {
        if let existing = connection {
            return existing
        }

        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: CleanerXPCProtocol.self)

        // Invalidation Handler
        newConnection.invalidationHandler = { [weak self] in
            self?.logger.warning("⚠️ XPC bağlantısı geçersiz kılındı (invalidated). Temizlik yapılıyor.")
            self?.connection = nil
        }

        // Interruption Handler
        newConnection.interruptionHandler = { [weak self] in
            self?.logger.warning("⚠️ XPC bağlantısı kesintiye uğradı (interrupted). Yeniden bağlanılacak.")
            self?.connection = nil
        }

        newConnection.resume()
        connection = newConnection

        logger.info("✅ XPC bağlantısı kuruldu: \(self.machServiceName)")
        return newConnection
    }

    // MARK: - IPC Doğrulama ve Hazırlık Talebi

    /// UI ve İletişim Bariyeri üzerinden filtrelenmiş mutlak dosya yollarını (`[String]`)
    /// Privileged Helper Tool'a iletir.
    /// - Parameter paths: UI tarafından filtrelenmiş ve onaylanmış mutlak fiziksel dosya yolları.
    /// - Returns: Helper işlemi onayladığında `true`.
    func verifyAndPrepareDeletion(paths: [String]) async throws -> Bool {
        let xpcConnection = establishConnection()

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = xpcConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.logger.error("🛑 XPC proxy iletişim hatası: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }) as? CleanerXPCProtocol else {
                continuation.resume(throwing: XPCConnectionError.proxyUnavailable)
                return
            }

            proxy.verifyAndPrepareDeletion(paths: paths) { success, error in
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
