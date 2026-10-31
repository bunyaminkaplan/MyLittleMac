//
//  ProcessLifecycleService.swift
//  my_little_mac
//
//  Process Lifecycle & Service Termination Agent:
//  Hedef uygulamaya ait çalışan canlı süreçleri (live processes) ve launchd arka plan
//  servislerini (LaunchDaemons / LaunchAgents) güvenli bir şekilde sonlandırır.
//  Girdi: KESİNLİKLE [ScannedFile] (Swift Struct) listesi ve hedef ScannedApp.
//  Tahribat Engeli: Fiziksel dosya silme kodu KESİNLİKLE İÇERMEZ.
//

import Foundation
import AppKit
import ServiceManagement
import os.log

// MARK: - Süreç ve İşlem Raporlama Modelleri

struct ProcessTerminationInfo: Codable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let bundleIdentifier: String
    let processName: String
    let wasGraceful: Bool
    let isTerminated: Bool
}

struct LifecycleOperationReport {
    let targetBundleID: String
    let targetAppName: String
    let terminatedProcesses: [ProcessTerminationInfo]
    let approvedPlistFiles: [ScannedFile]
    let approvedFiles: [ScannedFile]
    let approvedPaths: [String]
    let isHelperDryRunSuccessful: Bool
    let timestamp: Date
}

// MARK: - ProcessLifecycleService

final class ProcessLifecycleService {

    private let logger = Logger(subsystem: "bunyamin.my-little-mac", category: "ProcessLifecycleService")
    private let xpcConnectionManager: XPCConnectionManager

    init(xpcConnectionManager: XPCConnectionManager = XPCConnectionManager()) {
        self.xpcConnectionManager = xpcConnectionManager
    }

    // MARK: - 1. Süreç Sonlandırma (Live Process Termination)

    /// İşlem yapılacak hedefin CFBundleIdentifier bilgisini kullanarak NSWorkspace.shared.runningApplications
    /// üzerinden bellek taraması yapar.
    /// Uygulama veya ilişkili süreçler çalışıyorsa KESİNLİKLE önce terminate() ile zarif kapanma sinyali gönderir.
    /// 5 saniye içinde kapanmazsa forceTerminate() (SIGKILL) ile süreci zorla sonlandırır.
    @discardableResult
    func terminateRunningProcesses(for bundleID: String) async -> [ProcessTerminationInfo] {
        let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanBundleID.isEmpty else { return [] }

        // Hedef uygulama veya alt yardımcı süreçleri (Örn: com.google.Chrome, com.google.Chrome.helper)
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let appID = app.bundleIdentifier?.lowercased() else { return false }
            return appID == cleanBundleID || appID.hasPrefix(cleanBundleID + ".")
        }

        guard !runningApps.isEmpty else {
            logger.info("ℹ️ Hedef [\(bundleID)] için çalışan aktif GUI/arka plan süreci bulunamadı.")
            return []
        }

        var results: [ProcessTerminationInfo] = []

        for app in runningApps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? bundleID
            let appBundleID = app.bundleIdentifier ?? bundleID

            logger.info("⚠️ Çalışan süreç tespit edildi: [\(name)] (PID: \(pid), ID: \(appBundleID)). terminate() gönderiliyor...")

            let terminateSent = app.terminate()
            var wasGraceful = false

            if terminateSent {
                // 5 saniye boyunca zarif kapanmayı (SIGTERM) bekle
                let deadline = Date().addingTimeInterval(5.0)
                while Date() < deadline {
                    if app.isTerminated {
                        wasGraceful = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }

            // 5 saniye içinde kapanmadıysa zorla sonlandır (SIGKILL)
            if !app.isTerminated {
                logger.warning("⏱️ Süreç 5 saniye içinde kapanmadı: [\(name)] (PID: \(pid)). forceTerminate() (SIGKILL) uygulanıyor...")
                _ = app.forceTerminate()

                let forceDeadline = Date().addingTimeInterval(1.0)
                while Date() < forceDeadline {
                    if app.isTerminated { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            let isTerminated = app.isTerminated
            logger.info("🏁 Süreç sonlandırma tamamlandı: [\(name)] (PID: \(pid), Zarif: \(wasGraceful), Sonlandı: \(isTerminated))")

            results.append(
                ProcessTerminationInfo(
                    pid: pid,
                    bundleIdentifier: appBundleID,
                    processName: name,
                    wasGraceful: wasGraceful,
                    isTerminated: isTerminated
                )
            )
        }

        return results
    }

    // MARK: - 2. Ajanlar Arası İletişim & Hazırlık Yürütücüsü

    /// Tarama ajanından gelen [ScannedFile] (Swift Struct) listesini girdi olarak alır.
    /// 1. Hedefin canlı süreçlerini sonlandırır (terminate -> 5s -> forceTerminate).
    /// 2. Yalnızca onaylı (isSelectedForDeletion == true ve .safeToDelete) .plist dosyalarını ve yolları ayıklar (UI Güvenlik Bariyeri).
    /// 3. XPC Helper üzerinden servis boşaltma (unload) ve dry-run simülasyonunu çalıştırır.
    /// 4. Güncellenmiş LifecycleOperationReport nesnesini UI ve Audit ajanına döner.
    func executeLifecycleAndDryRun(
        for app: ScannedApp,
        files: [ScannedFile]
    ) async throws -> LifecycleOperationReport {
        // UI Güvenlik Bariyeri:
        // Yalnızca isSelectedForDeletion == true olan VE
        // mutlak sahiplik kanıtı olan (.safeToDelete) dosyaları filtrele.
        // Ortak kullanım (.sharedDependency), yüksek riskli (.highRisk) veya belirsiz (.unknown) dosyalar KESİNLİKLE iletilemez.
        let approvedFiles = files.filter {
            $0.isSelectedForDeletion &&
            $0.riskLevel != .unknown &&
            $0.riskLevel != .highRisk &&
            $0.riskLevel != .sharedDependency
        }
        let approvedPaths = approvedFiles.map { $0.url.standardizedFileURL.path }

        guard !approvedPaths.isEmpty else {
            throw NSError(
                domain: "ProcessLifecycleError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Silinmek üzere onaylanmış güvenli dosya bulunamadı. Kilitli veya riskli dosyalar doğrudan temizlenemez."]
            )
        }

        // Onaylanmış LaunchDaemon / LaunchAgent .plist dosyaları
        let approvedPlistFiles = approvedFiles.filter {
            $0.fileType == .launchDaemon ||
            $0.fileType == .launchAgent ||
            ($0.url.pathExtension == "plist" && ($0.path.contains("/LaunchDaemons/") || $0.path.contains("/LaunchAgents/")))
        }

        // Adım 1: Canlı Süreçleri Sonlandırma (terminate() -> 5s -> forceTerminate())
        let terminatedProcesses = await terminateRunningProcesses(for: app.bundleIdentifier)

        // Adım 2: XPC Privileged Helper üzerinden Servis Boşaltma ve Dry-Run Simülasyonu
        let success = try await xpcConnectionManager.verifyAndPrepareDeletion(
            bundleID: app.bundleIdentifier,
            paths: approvedPaths
        )

        return LifecycleOperationReport(
            targetBundleID: app.bundleIdentifier,
            targetAppName: app.name,
            terminatedProcesses: terminatedProcesses,
            approvedPlistFiles: approvedPlistFiles,
            approvedFiles: approvedFiles,
            approvedPaths: approvedPaths,
            isHelperDryRunSuccessful: success,
            timestamp: Date()
        )
    }
}
