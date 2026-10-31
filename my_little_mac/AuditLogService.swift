//
//  AuditLogService.swift
//  my_little_mac
//
//  Raporlama ve Denetim (Audit) Ajanı: XPC Privileged Helper üzerinden başarıyla
//  dry-run testinden geçmiş verilerin kalıcı kaydını oluşturur.
//  ~/Library/Logs/my_little_mac/clean_audit_[TIMESTAMP].json formatında arşivler.
//  Tahribat Engeli: Fiziksel dosya silme kodu KESİNLİKLE İÇERMEZ.
//

import Foundation
import ServiceManagement
import os.log
import Darwin

// MARK: - Denetim Günlüğü Modelleri (Codable)

/// Arşivlenecek denetim kaydının ana kök modeli.
struct AuditLogRecord: Codable {
    let auditVersion: String
    let reportTimestamp: String
    let action: String
    let simulationResult: String

    // 1. CFBundleIdentifier ve Hedef Uygulama Bilgisi
    let bundleIdentifier: String
    let targetApplication: AuditTargetAppInfo

    // 2. Kullanıcı İzin ve Yetki Durumu
    let userAuthorization: AuditUserAuthorizationInfo

    // 3. Simülasyon ve İstatistik Özeti (Dry-Run)
    let summary: AuditSummaryInfo

    // 4. Sadece XPC tarafından onaylanmış ve isSelectedForDeletion == true durumundaki mutlak dosya yolları ([String])
    let approvedPaths: [String]

    // 5. Onaylanan dosya öğelerinin ayrıntılı dökümü
    let approvedItems: [AuditItemDetail]

    // 6. Sonlandırılan Canlı Süreçler (Live Process Lifecycle)
    let terminatedProcesses: [ProcessTerminationInfo]?
}

/// Hedef uygulamanın kimlik ve paket bilgileri.
struct AuditTargetAppInfo: Codable {
    let bundleIdentifier: String
    let name: String
    let mainAppPath: String
}

/// İşlemi gerçekleştiren kullanıcının sistem ve ayrıcalık izin durumu.
struct AuditUserAuthorizationInfo: Codable {
    let username: String
    let userID: UInt32
    let isAdministrator: Bool
    let privilegedHelperStatus: String
    let isPrivilegedHelperAuthorized: Bool
    let authorizationScope: String
}

/// Simülasyon ve tahribat engeli özet metrikleri.
struct AuditSummaryInfo: Codable {
    let totalApprovedFilesCount: Int
    let totalApprovedSizeBytes: Int64
    let totalApprovedSizeFormatted: String
    let isDryRunSimulation: Bool
    let filesDeleted: Bool
    let terminatedProcessesCount: Int
    let securityBarrierNotice: String
}

/// Onaylanmış her bir dosyanın detay kaydı.
struct AuditItemDetail: Codable {
    let path: String
    let sizeBytes: Int64
    let sizeFormatted: String
    let fileType: String
    let riskLevel: String
    let discoveryMethod: String
    let isSelectedForDeletion: Bool
    let dryRunStatus: String
}

// MARK: - AuditLogService

/// Raporlama ve Denetim (Audit) Servisi
final class AuditLogService {

    private let logger = Logger(subsystem: "bunyamin.my-little-mac", category: "AuditLogService")

    init() {}

    // MARK: - Dizin Yönetimi

    /// ~/Library/Logs/my_little_mac/ dizin URL'sini döner.
    /// Dizin henüz mevcut değilse güvenle oluşturur.
    func getOrCreateLogsDirectory() throws -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let logsDir = homeDir
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("my_little_mac", isDirectory: true)

        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
            logger.info("📁 Denetim günlüğü dizini oluşturuldu: \(logsDir.path, privacy: .public)")
        }
        return logsDir
    }

    // MARK: - Denetim Günlüğü Kaydı (Audit Log Recording)

    /// XPC servisinden başarıyla dönen `[ScannedFile]` (Swift Struct) listesini alır,
    /// sadece isSelectedForDeletion == true ve güvenlik bariyerinden geçmiş mutlak yolları filtreler,
    /// kullanıcının izin durumunu tespit eder ve clean_audit_[TIMESTAMP].json dosyasına kalıcı olarak yazar.
    ///
    /// - Parameters:
    ///   - app: Hedef uygulama (CFBundleIdentifier bilgisini içerir).
    ///   - verifiedFiles: XPC Privileged Helper tarafından doğrulanan `[ScannedFile]` listesi.
    ///   - helperStatus: SMAppService üzerinden alınan Privileged Helper izin durumu.
    ///   - terminatedProcesses: ProcessLifecycleService tarafından sonlandırılan aktif süreçler.
    /// - Returns: Oluşturulan ve kaydedilen JSON dosyasının dosya yolu URL'si.
    @discardableResult
    func recordDryRunAuditLog(
        for app: ScannedApp,
        verifiedFiles: [ScannedFile],
        helperStatus: SMAppService.Status,
        terminatedProcesses: [ProcessTerminationInfo] = []
    ) throws -> URL {
        // UI Güvenlik Bariyeri & Ajanlar Arası İletişim Protokolü:
        // Yalnızca isSelectedForDeletion == true olan VE
        // belirsiz (.unknown), yüksek riskli (.highRisk) veya paylaşılan (.sharedDependency) OLMAYAN
        // dosyaları filtrele.
        let eligibleFiles = verifiedFiles.filter {
            $0.isSelectedForDeletion &&
            $0.riskLevel != .unknown &&
            $0.riskLevel != .highRisk &&
            $0.riskLevel != .sharedDependency
        }

        // Loglanacak veri: Sadece XPC tarafından onaylanmış ve isSelectedForDeletion == true durumundaki [String] mutlak yollar
        let approvedPaths: [String] = eligibleFiles.map { $0.url.standardizedFileURL.path }

        // 1. Kullanıcı İzin ve Yetki Durumunun Tespiti
        let username = NSUserName()
        let uid = getuid()

        // macOS grup kontrolü (admin = GID 80 veya root = UID 0)
        var groups = [gid_t](repeating: 0, count: 64)
        let ngroups = getgroups(64, &groups)
        let isAdmin = (uid == 0) || (ngroups > 0 && groups.prefix(Int(ngroups)).contains(80))

        let helperStatusStr: String
        let isHelperAuthorized: Bool
        switch helperStatus {
        case .enabled:
            helperStatusStr = "enabled"
            isHelperAuthorized = true
        case .requiresApproval:
            helperStatusStr = "requiresApproval (Bekleyen Sistem Ayarları Onayı)"
            isHelperAuthorized = false
        case .notRegistered:
            helperStatusStr = "notRegistered"
            isHelperAuthorized = false
        case .notFound:
            helperStatusStr = "notFound"
            isHelperAuthorized = false
        @unknown default:
            helperStatusStr = "unknown (\(helperStatus.rawValue))"
            isHelperAuthorized = false
        }

        let userAuth = AuditUserAuthorizationInfo(
            username: username,
            userID: uid,
            isAdministrator: isAdmin,
            privilegedHelperStatus: helperStatusStr,
            isPrivilegedHelperAuthorized: isHelperAuthorized,
            authorizationScope: isHelperAuthorized
                ? "SMAppService.daemon (Privileged LaunchDaemon / Root)"
                : "Standart Kullanıcı Seviyesi"
        )

        // 2. Hedef Uygulama Bilgisi (CFBundleIdentifier)
        let targetAppInfo = AuditTargetAppInfo(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            mainAppPath: app.mainAppUrl.standardizedFileURL.path
        )

        // 3. Boyut ve Özet Hesaplama
        let totalBytes = eligibleFiles.reduce(0) { $0 + $1.size }
        let byteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useAll]
        byteFormatter.countStyle = .file
        let formattedSize = byteFormatter.string(fromByteCount: totalBytes)

        let summary = AuditSummaryInfo(
            totalApprovedFilesCount: eligibleFiles.count,
            totalApprovedSizeBytes: totalBytes,
            totalApprovedSizeFormatted: formattedSize,
            isDryRunSimulation: true,
            filesDeleted: false,
            terminatedProcessesCount: terminatedProcesses.count,
            securityBarrierNotice: "Tahribat engeli kuralı gereği hiçbir dosya silinmemiş veya taşınmamıştır. Yalnızca FileManager.default.isDeletableFile ile dry-run simülasyonu yapılmıştır."
        )

        // 4. Detaylı Öğe Listesi
        let itemDetails: [AuditItemDetail] = eligibleFiles.map { file in
            AuditItemDetail(
                path: file.url.standardizedFileURL.path,
                sizeBytes: file.size,
                sizeFormatted: byteFormatter.string(fromByteCount: file.size),
                fileType: file.fileType.rawValue,
                riskLevel: "\(file.riskLevel) (\(file.riskLevel.rawValue))",
                discoveryMethod: file.discoveryMethod.rawValue,
                isSelectedForDeletion: file.isSelectedForDeletion,
                dryRunStatus: "dry_run_successful"
            )
        }

        // 5. Zaman Damgası ve Kayıt Oluşturma
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoDateStr = isoFormatter.string(from: now)

        let record = AuditLogRecord(
            auditVersion: "1.0",
            reportTimestamp: isoDateStr,
            action: "xpc_privileged_dry_run_audit",
            simulationResult: "success",
            bundleIdentifier: app.bundleIdentifier,
            targetApplication: targetAppInfo,
            userAuthorization: userAuth,
            summary: summary,
            approvedPaths: approvedPaths,
            approvedItems: itemDetails,
            terminatedProcesses: terminatedProcesses.isEmpty ? nil : terminatedProcesses
        )

        // 6. ~/Library/Logs/my_little_mac/clean_audit_[TIMESTAMP].json Yoluna Yazma
        let logsDir = try getOrCreateLogsDirectory()

        let filenameFormatter = DateFormatter()
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestampStr = filenameFormatter.string(from: now)

        var finalFilename = "clean_audit_\(timestampStr).json"
        var targetFileURL = logsDir.appendingPathComponent(finalFilename)

        // Çakışma koruması: Aynı saniye içinde dosya varsa benzersiz ek koy
        var collisionCounter = 1
        while FileManager.default.fileExists(atPath: targetFileURL.path) {
            finalFilename = "clean_audit_\(timestampStr)_\(collisionCounter).json"
            targetFileURL = logsDir.appendingPathComponent(finalFilename)
            collisionCounter += 1
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: targetFileURL, options: .atomic)

        logger.info("✅ [AuditLogService] Denetim günlüğü kaydedildi: \(targetFileURL.path, privacy: .public)")
        print("[AuditLogService] ✅ Denetim günlüğü başarıyla kaydedildi: \(targetFileURL.path)")

        return targetFileURL
    }
}
