//
//  XPCConnectionManager.swift
//  my_little_mac
//
//  XPC Helper Agent: Ana uygulama tarafında çalışan XPC bağlantı yöneticisi.
//  SMAppService.daemon(plistName:) ile modern macOS 14+ daemon kurulumu,
//  NSXPCConnection ile IPC bağlantısı, invalidation/interruption temizliği.
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

    var errorDescription: String? {
        switch self {
        case .connectionInvalidated:
            return "XPC bağlantısı geçersiz kılındı (invalidated)."
        case .connectionInterrupted:
            return "XPC bağlantısı kesintiye uğradı (interrupted)."
        case .proxyUnavailable:
            return "XPC proxy nesnesi alınamadı."
        case .daemonInstallationFailed(let error):
            return "Daemon kurulumu başarısız: \(error.localizedDescription)"
        }
    }
}

// MARK: - XPC Connection Manager (Ana Uygulama Tarafı)

/// Ana uygulama ile Privileged Helper Tool arasındaki XPC bağlantısını yönetir.
/// macOS 14+ `SMAppService` altyapısını kullanır.
final class XPCConnectionManager {

    /// Helper Tool'un Mach servis adı.
    private let machServiceName = "com.mylittlemac.xpchelper"

    /// Daemon kurulumu için launchd plist dosya adı.
    private let daemonPlistName = "com.mylittlemac.xpchelper.plist"

    private var connection: NSXPCConnection?
    private let logger = Logger(subsystem: "com.mylittlemac.app", category: "XPCConnectionManager")

    // MARK: - Daemon Kurulumu (SMAppService)

    /// `SMAppService.daemon(plistName:)` kullanarak daemon'ı sisteme kaydeder.
    /// Eski `SMJobBless` / `SMPrivilegedExecutables` kullanılmaz.
    func installDaemon() throws {
        let service = SMAppService.daemon(plistName: daemonPlistName)

        do {
            try service.register()
            logger.info("✅ Daemon başarıyla kaydedildi: \(self.daemonPlistName)")
        } catch {
            logger.error("🛑 Daemon kayıt hatası: \(error.localizedDescription)")
            throw XPCConnectionError.daemonInstallationFailed(error)
        }
    }

    /// Daemon'ı sistemden kaldırır.
    func uninstallDaemon() throws {
        let service = SMAppService.daemon(plistName: daemonPlistName)

        do {
            try service.unregister()
            logger.info("✅ Daemon başarıyla kaldırıldı: \(self.daemonPlistName)")
        } catch {
            logger.error("🛑 Daemon kaldırma hatası: \(error.localizedDescription)")
            throw XPCConnectionError.daemonInstallationFailed(error)
        }
    }

    // MARK: - XPC Bağlantısı

    /// XPC bağlantısını oluşturur ve yapılandırır.
    /// Bağlantı koptuğunda (invalidation/interruption) temizlik mekanizmalarını kurar.
    private func establishConnection() -> NSXPCConnection {
        // Mevcut bağlantı varsa yeniden kullan
        if let existing = connection {
            return existing
        }

        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)

        // Dışa açılan arayüz — Helper Tool'un sunduğu protokol
        newConnection.remoteObjectInterface = NSXPCInterface(with: CleanerXPCProtocol.self)

        // ── Invalidation Handler ──
        newConnection.invalidationHandler = { [weak self] in
            self?.logger.warning("⚠️ XPC bağlantısı geçersiz kılındı (invalidated). Temizlik yapılıyor.")
            self?.connection = nil
        }

        // ── Interruption Handler ──
        newConnection.interruptionHandler = { [weak self] in
            self?.logger.warning("⚠️ XPC bağlantısı kesintiye uğradı (interrupted). Yeniden bağlanma gerekebilir.")
            self?.connection = nil
        }

        newConnection.resume()
        connection = newConnection

        logger.info("✅ XPC bağlantısı kuruldu: \(self.machServiceName)")
        return newConnection
    }

    // MARK: - Silme Talebi Gönderimi

    /// UI'dan gelen `[ScannedFile]` listesini `[URL]` dizisine dönüştürerek
    /// XPC servisi üzerinden silme talebini gönderir.
    /// - Parameter urls: Silinmesi onaylanan dosya yollarının `[URL]` dizisi.
    /// - Returns: İşlem başarılı ise `true`.
    func requestRemoval(urls: [URL]) async throws -> Bool {
        let xpcConnection = establishConnection()

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = xpcConnection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? CleanerXPCProtocol else {
                continuation.resume(throwing: XPCConnectionError.proxyUnavailable)
                return
            }

            proxy.removeFiles(at: urls) { success, error in
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
