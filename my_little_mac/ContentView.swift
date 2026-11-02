//
//  ContentView.swift
//  my_little_mac
//
//  Created by Bünyamin Kaplan on 12.10.2026.
//
//  UI Mimari Ajanı: SwiftUI tabanlı durum yönetimi (State Management),
//  akordeon (DisclosureGroup) listeleme, tam satır tıklanabilirlik (.contentShape),
//  karma (mixed) durum destekli kategori checkbox'ları, animasyonlu kilit geçişleri,
//  HIG uyumlu Toolbar kontrolleri ve UI Güvenlik Bariyeri.
//  Silme kodu İÇERMEZ. Sadece dry-run simülasyonu tetikler.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Kategori Seçim Durumu (Karma / Mixed Durum Desteği)

enum CategorySelectionState {
    case allSelected
    case mixed
    case noneSelected
}

// MARK: - Helper Durumu (Salt Okunur Toolbar Rozeti)

/// Privileged Helper bağlantısının kullanıcıya yansıtılan durumu.
/// Toolbar rozeti yalnızca bu durumu GÖSTERİR; kullanıcı durumu değiştiremez.
enum HelperStatus: CaseIterable, Equatable {
    case connected
    case connecting
    case disconnected

    var title: String {
        switch self {
        case .connected: return "Helper Açık"
        case .connecting: return "Bağlanıyor…"
        case .disconnected: return "Helper Kapalı"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }

    var helpText: String {
        switch self {
        case .connected:
            return "Privileged Helper bağlı ve root (UID: 0) yetkisi doğrulandı."
        case .connecting:
            return "Privileged Helper'a bağlanılıyor ve root yetkisi doğrulanıyor…"
        case .disconnected:
            return "Privileged Helper şu an bağlı değil. 'Temizle / Simüle Et' işlemi başlatıldığında bağlantı otomatik kurulur ve root yetkisi doğrulanır."
        }
    }
}

/// Helper'ın root yerine kullanıcı yetkisiyle çalıştığı tespit edildiğinde fırlatılır.
enum HelperAuthorityError: LocalizedError {
    case notRoot(uid: Int, pid: Int)

    var errorDescription: String? {
        switch self {
        case let .notRoot(uid, pid):
            return "🛑 [GÜVENLİK İHLALİ] Remote Execution doğrulanamadı: Helper root (UID: 0) yerine kullanıcı yetkisiyle (UID: \(uid), PID: \(pid)) çalışıyor. İşlem iptal edildi."
        }
    }
}

// MARK: - ViewModel (@Observable)

@Observable
final class ContentViewModel {
    var scannedApp: ScannedApp?
    var isAdvancedModeUnlocked: Bool = false
    var isScanning: Bool = false
    var scanError: String?
    var isDeleting: Bool = false
    var deletionError: String?
    var deletionSuccessMessage: String?
    var isWaitingForApproval: Bool = false
    var pendingDeletionFiles: [ScannedFile] = []
    var lastAuditLogURL: URL?
    var isHelperConnectionActive: Bool = false
    var isRootVerified: Bool = false
    var isConnectingHelper: Bool = false

    /// Toolbar rozetinin gösterdiği salt okunur Helper durumu.
    var helperStatus: HelperStatus {
        if isHelperConnectionActive && isRootVerified { return .connected }
        if isConnectingHelper || isHelperConnectionActive { return .connecting }
        return .disconnected
    }

    /// Tarama veya dry-run sürerken toolbar kontrolleri kilitlenir (yarış durumu koruması).
    var isBusy: Bool { isScanning || isDeleting }

    @ObservationIgnored private let scannerService = ScannerService()
    @ObservationIgnored private let analyzerService = AnalyzerService()
    @ObservationIgnored private let xpcConnectionManager: XPCConnectionManager
    @ObservationIgnored private let auditLogService = AuditLogService()
    @ObservationIgnored private let lifecycleService: ProcessLifecycleService

    init(xpcConnectionManager: XPCConnectionManager = XPCConnectionManager()) {
        self.xpcConnectionManager = xpcConnectionManager
        self.lifecycleService = ProcessLifecycleService(xpcConnectionManager: xpcConnectionManager)
        self.isHelperConnectionActive = xpcConnectionManager.isConnected
        self.isRootVerified = false

        // Helper bağlantı durumu dinleyicisi:
        // Bağlantı kesildiğinde (invalidated) veya uykuya geçtiğinde UI durumunu günceller.
        self.xpcConnectionManager.onConnectionStateChanged = { [weak self] isConnected in
            Task { @MainActor [weak self] in
                self?.isHelperConnectionActive = isConnected
                if !isConnected {
                    self?.isRootVerified = false
                }
            }
        }
    }

    /// XPC bağlantısını kurar ve Remote Execution kanıtı olarak root (UID: 0) yetkisini doğrular.
    /// Doğrulama başarısızsa bağlantıyı düşürür ve hatayı fırlatır.
    @MainActor
    private func establishVerifiedHelperConnection() async throws {
        isConnectingHelper = true
        defer { isConnectingHelper = false }

        do {
            try xpcConnectionManager.connectManually()
            let auth = try await xpcConnectionManager.verifyRootAuthority()
            guard auth.isRoot && auth.uid == 0 else {
                xpcConnectionManager.invalidateConnection()
                throw HelperAuthorityError.notRoot(uid: auth.uid, pid: auth.pid)
            }
            isRootVerified = true
            isHelperConnectionActive = true
        } catch {
            isRootVerified = false
            isHelperConnectionActive = false
            throw error
        }
    }

    /// Açılışta çağrılır: Helper bağlantısını kurar ve root yetkisini doğrular.
    /// Helper bağlantısı kullanıcı tarafından keyfi olarak açılıp kapatılamaz;
    /// sonraki bağlantılar `requestDeletion` içinde talep üzerine kurulur.
    @MainActor
    func connectHelper() async {
        do {
            try await establishVerifiedHelperConnection()
            deletionError = nil
        } catch let error as HelperAuthorityError {
            deletionError = error.localizedDescription
        } catch {
            deletionError = "Helper bağlantısı kurulamadı veya root yetkisi doğrulanamadı: \(error.localizedDescription)"
        }
    }

    func openLogsDirectory() {
        if let url = try? auditLogService.getOrCreateLogsDirectory() {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettings() {
        xpcConnectionManager.openSystemSettingsForApproval()
    }

    func cancelPendingDeletion() {
        isWaitingForApproval = false
        pendingDeletionFiles = []
    }

    @MainActor
    func retryPendingDeletion() async {
        isWaitingForApproval = false
        let files = pendingDeletionFiles
        pendingDeletionFiles = []
        // requestDeletion, bağlantı yoksa Helper'a kendisi bağlanıp root yetkisini doğrular.
        await requestDeletion(files: files)
    }

    /// Sadece `isSelectedForDeletion == true` olan dosyaların toplam boyutu.
    var totalSelectedSize: Int64 {
        guard let app = scannedApp else { return 0 }
        return app.relatedFiles
            .filter { $0.isSelectedForDeletion }
            .reduce(0) { $0 + $1.size }
    }

    /// Dosyaları FileType enum'una göre gruplandırarak döner.
    var groupedFiles: [(fileType: FileType, files: [ScannedFile])] {
        guard let app = scannedApp else { return [] }

        let grouped = Dictionary(grouping: app.relatedFiles) { $0.fileType }
        return grouped
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { (fileType: $0.key, files: $0.value) }
    }

    /// Seçili dosyalar (isSelectedForDeletion == true).
    var selectedFiles: [ScannedFile] {
        scannedApp?.relatedFiles.filter { $0.isSelectedForDeletion } ?? []
    }

    // MARK: - XPC IPC Köprü Metodu (UI, Yaşam Döngüsü & İletişim Bariyeri)

    /// SADECE `isSelectedForDeletion == true` olan [ScannedFile] objelerini ProcessLifecycleService üzerinden işler.
    /// Canlı süreçleri (live processes) sonlandırır, onaylanmış .plist servislerini unload eder ve
    /// fiziksel yolları (`[String]`) XPC servisine gönderip dry-run simülasyonunu tamamlar.
    @MainActor
    func requestDeletion(files: [ScannedFile]) async {
        guard let currentApp = scannedApp, !currentApp.bundleIdentifier.isEmpty else {
            deletionError = "Hedef uygulamanın Bundle ID'si belirlenemedi."
            return
        }

        // UI Güvenlik Bariyeri: Yalnızca isSelectedForDeletion == true olan dosyaları filtrele.
        // Kilit açılmamışsa, yüksek riskli veya ortak kullanım şüphesi taşıyan dosyalar KESİNLİKLE gönderilemez.
        let approvedFiles: [ScannedFile]
        if isAdvancedModeUnlocked {
            approvedFiles = files.filter { $0.isSelectedForDeletion }
        } else {
            approvedFiles = files.filter {
                $0.isSelectedForDeletion &&
                $0.riskLevel != .unknown &&
                $0.riskLevel != .highRisk &&
                $0.riskLevel != .sharedDependency
            }
        }

        let approvedPaths: [String] = approvedFiles.map { $0.url.standardizedFileURL.path }

        // Kilitli / seçilmemiş hiçbir dosya yolu iletilemez; liste boşsa durdur
        guard !approvedPaths.isEmpty else {
            if !files.isEmpty {
                deletionError = "Silinmek üzere onaylanmış güvenli dosya bulunamadı. Kilitli (.highRisk, .sharedDependency, .unknown) dosyaları dahil etmek için lütfen araç çubuğundaki kilit butonunu açınız."
            }
            return
        }

        // Bağlantı kurulumu dahil tüm süreç boyunca UI kilitlenir (toolbar + footer).
        isDeleting = true
        defer { isDeleting = false }
        deletionError = nil
        deletionSuccessMessage = nil

        // Talep üzerine bağlantı: Helper rozeti salt okunurdur; bağlantı (önceki dry-run sonrası
        // idle-exit ile kapanmışsa) burada yeniden kurulur ve root yetkisi yeniden doğrulanır.
        if !(isHelperConnectionActive && isRootVerified) {
            do {
                try await establishVerifiedHelperConnection()
            } catch XPCConnectionError.requiresApproval {
                pendingDeletionFiles = approvedFiles
                isWaitingForApproval = true
                return
            } catch {
                deletionError = error.localizedDescription
                return
            }
        }

        // UI Güvenlik Bariyeri: Helper bağlantısı kapalıyken veya root yetkisi doğrulanamamışsa
        // arayüzden tetiklenen hiçbir [ScannedFile] (risk düzeyi ne olursa olsun) Helper'a gönderilemez!
        guard isHelperConnectionActive && isRootVerified else {
            deletionError = "🛑 UI Güvenlik Bariyeri: XPC proxy üzerinden root yetkisi (UID: 0) doğrulanamadığı sürece işlem başlatılamaz."
            return
        }

        do {
            let report = try await lifecycleService.executeLifecycleAndDryRun(
                for: currentApp,
                files: approvedFiles
            )

            if report.isHelperDryRunSuccessful {
                // Ajanlar Arası İletişim (Veri Protokolü):
                // XPC servisinden ve Lifecycle ajanından dönen olumlu sonuçlar, Raporlama/Denetim ajanına
                // KESİNLİKLE [ScannedFile] listesi ve sonlandırılan canlı süreçler olarak aktarılır.
                do {
                    let logURL = try auditLogService.recordDryRunAuditLog(
                        for: currentApp,
                        verifiedFiles: report.approvedFiles,
                        helperStatus: xpcConnectionManager.daemonStatus(),
                        terminatedProcesses: report.terminatedProcesses,
                        helperPID: report.helperPID,
                        helperUID: report.helperUID
                    )
                    lastAuditLogURL = logURL

                    // Denetim günlüğünü (Audit Log) başarıyla kaydettiğinde
                    // XPCConnectionManager sınıfı KESİNLİKLE connection?.invalidate() çağrısını tetikler.
                    xpcConnectionManager.invalidateConnection()
                    isHelperConnectionActive = false
                    isRootVerified = false

                    var successMsg = "\(report.approvedPaths.count) dosya yolu Privileged Helper tarafından doğrulandı ve simüle edildi (Dry-run başarılı).\n🛡️ Remote Execution Kanıtı: Root UID: \(report.helperUID), Helper PID: \(report.helperPID)"

                    if !report.terminatedProcesses.isEmpty {
                        let procDetails = report.terminatedProcesses.map { proc in
                            let mode = proc.wasGraceful ? "Zarif (terminate)" : "Zorla (forceTerminate)"
                            return "• \(proc.processName) (PID: \(proc.pid), \(mode))"
                        }.joined(separator: "\n")
                        successMsg += "\n\n⚡ Sonlandırılan Canlı Süreçler (\(report.terminatedProcesses.count) adet):\n\(procDetails)"
                    }

                    if !report.approvedPlistFiles.isEmpty {
                        let plistNames = report.approvedPlistFiles.map { "• \($0.url.lastPathComponent)" }.joined(separator: "\n")
                        successMsg += "\n\n🛑 Bellekten Düşürülen Servisler (\(report.approvedPlistFiles.count) adet):\n\(plistNames)"
                    }

                    successMsg += "\n\n📄 Denetim Günlüğü Kaydedildi:\n\(logURL.path)"
                    deletionSuccessMessage = successMsg
                } catch {
                    xpcConnectionManager.invalidateConnection()
                    isHelperConnectionActive = false
                    isRootVerified = false
                    deletionSuccessMessage = "\(report.approvedPaths.count) dosya yolu Privileged Helper tarafından doğrulandı ve simüle edildi (Dry-run başarılı)."
                    deletionError = "Denetim günlüğü kaydedilemedi: \(error.localizedDescription)"
                }

                // Helper'dan dönen başarılı sonucu [ScannedFile] modellerinin durumunu UI'da güncellemek için kullan
                let approvedSet = Set(report.approvedPaths)
                for index in currentApp.relatedFiles.indices {
                    if approvedSet.contains(currentApp.relatedFiles[index].url.standardizedFileURL.path) {
                        scannedApp?.relatedFiles[index].isSelectedForDeletion = false
                    }
                }
            }
        } catch let error as XPCConnectionError {
            xpcConnectionManager.invalidateConnection()
            isHelperConnectionActive = false
            isRootVerified = false
            if case .requiresApproval = error {
                pendingDeletionFiles = approvedFiles
                isWaitingForApproval = true
                deletionError = nil
            } else {
                deletionError = error.localizedDescription
            }
        } catch {
            xpcConnectionManager.invalidateConnection()
            isHelperConnectionActive = false
            isRootVerified = false
            deletionError = error.localizedDescription
        }
    }

    // MARK: - Tarama Akışı

    /// Seçilen .app URL'sinden ScannedApp oluşturur ve Scanner → Analyzer
    /// ardışık akışını async olarak başlatır.
    @MainActor
    func startScan(appUrl: URL, isAdvancedModeEnabled: Bool = false) async {
        isScanning = true
        scanError = nil
        scannedApp = nil

        // .app paketinden uygulama adını ve bundle ID'yi çıkar
        let appName = appUrl.deletingPathExtension().lastPathComponent
        let bundleID = extractBundleID(from: appUrl) ?? "unknown"

        // ScannedApp modelini oluştur
        var app = ScannedApp(
            id: UUID(),
            bundleIdentifier: bundleID,
            name: appName,
            mainAppUrl: appUrl,
            relatedFiles: []
        )

        do {
            // Adım 1: ScannerService ile tarama
            let scannedFiles = try await scannerService.scan(
                appUrl: app.mainAppUrl,
                isAdvancedModeEnabled: isAdvancedModeEnabled
            )

            // Adım 2: AnalyzerService ile risk analizi
            let analyzedFiles = try await analyzerService.analyze(files: scannedFiles, for: app)

            // UI Güvenlik Bariyeri:
            // Mutlak sahiplik kanıtı olmayan, belirsiz (.unknown), ortak kullanım şüphesi taşıyan (.sharedDependency)
            // veya sistem için riskli olan (.highRisk) TÜM dosyalar varsayılan olarak "SEÇİLMEMİŞ" (isSelectedForDeletion = false) başlatılır.
            let securedFiles = analyzedFiles.map { file -> ScannedFile in
                var item = file
                if item.riskLevel != .safeToDelete {
                    item.isSelectedForDeletion = false
                }
                return item
            }

            // Analiz sonuçlarını ScannedApp'e yerleştir
            app.relatedFiles = securedFiles
            scannedApp = app
        } catch {
            scanError = error.localizedDescription
        }

        isScanning = false
    }

    /// Info.plist'ten CFBundleIdentifier okur. Başarısız olursa nil döner.
    private func extractBundleID(from appUrl: URL) -> String? {
        let plistURL = appUrl
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")

        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bundleID
    }
}

// MARK: - StableWidthText (Sabit Genişlikli, Geçişli Metin)

/// Tüm metin varyantlarını üst üste yerleştirip yalnızca `current` olanı gösterir.
/// Böylece genişlik her zaman en uzun varyanta eşittir (durum değişince zıplama olmaz)
/// ve varyantlar arasında opaklık geçişiyle yumuşak bir crossfade elde edilir.
/// Sabit pt değerleri yerine metne göre ölçüldüğü için yerelleştirme/Dynamic Type güvenlidir.
struct StableWidthText: View {
    let variants: [String]
    let current: String

    var body: some View {
        ZStack {
            ForEach(variants, id: \.self) { variant in
                Text(variant)
                    .opacity(variant == current ? 1 : 0)
                    .accessibilityHidden(variant != current)
            }
        }
        .fixedSize()
    }
}

// MARK: - MixedCheckboxView (macOS Karma / Indeterminate Checkbox)

struct MixedCheckboxView: View {
    let state: CategorySelectionState
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                switch state {
                case .allSelected:
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                case .mixed:
                    Image(systemName: "minus.square.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                case .noneSelected:
                    Image(systemName: "square")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(stateHelpText)
    }

    private var stateHelpText: String {
        switch state {
        case .allSelected:
            return "Tüm kategorideki seçimleri kaldır"
        case .mixed:
            return "Karma durum: Kurala göre tüm güvenli öğeleri seç"
        case .noneSelected:
            return "Kategorideki güvenli öğeleri seç"
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var viewModel = ContentViewModel()
    @AppStorage("isAdvancedModeEnabled") private var isAdvancedModeEnabled: Bool = false
    @State private var showSharedDependencyAlert = false
    @State private var sharedDependencyAlertFile: ScannedFile?
    @State private var isDropTargeted = false
    @State private var showExportSuccessAlert = false
    @State private var exportedFilePath = ""
    @State private var collapsedCategories: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isScanning {
                // ── Tarama Devam Ediyor Durumu ──
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Uygulama taranıyor ve risk analizi yapılıyor…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.scannedApp != nil {
                // ── Sonuç Ekranı: Header + Akordeon Liste + Footer ──
                headerSection

                Divider()

                fileListSection
                    .animation(.easeInOut(duration: 0.25), value: viewModel.isAdvancedModeUnlocked)

                Divider()

                footerSection
            } else {
                // ── Giriş Ekranı (Minimal Main View) ──
                appSelectionArea
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .toolbar {
            toolbarItems
        }
        .task {
            // Açılışta Helper bağlantısını ve root yetkisini otomatik doğrula
            await viewModel.connectHelper()
        }
        .onChange(of: isAdvancedModeEnabled) { _, newValue in
            if let app = viewModel.scannedApp {
                Task { @MainActor in
                    await viewModel.startScan(
                        appUrl: app.mainAppUrl,
                        isAdvancedModeEnabled: newValue
                    )
                }
            }
        }
        .alert(
            "⚠️ Paylaşılan Bağımlılık Uyarısı",
            isPresented: $showSharedDependencyAlert,
            presenting: sharedDependencyAlertFile
        ) { _ in
            Button("Yine de Seç", role: .destructive) {
                if let file = sharedDependencyAlertFile,
                   let index = fileIndex(for: file) {
                    viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = true
                }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Bu dosya başka uygulamalar veya sistem bileşenleri tarafından ortak kullanılıyor olabilir. Temizlenmesi ilgili uygulamaların kararlılığını etkileyebilir.")
        }
        .alert("Rapor Kaydedildi", isPresented: $showExportSuccessAlert) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("Tarama raporu başarıyla kaydedildi:\n\(exportedFilePath)")
        }
        .alert("XPC Doğrulama Başarılı", isPresented: Binding(
            get: { viewModel.deletionSuccessMessage != nil },
            set: { if !$0 { viewModel.deletionSuccessMessage = nil } }
        )) {
            if let logURL = viewModel.lastAuditLogURL {
                Button("Denetim Günlüğünü Göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            }
            Button("Tamam", role: .cancel) {}
        } message: {
            if let msg = viewModel.deletionSuccessMessage {
                Text(msg)
            }
        }
        .alert("XPC İletişim Hatası", isPresented: Binding(
            get: { viewModel.deletionError != nil },
            set: { if !$0 { viewModel.deletionError = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            if let err = viewModel.deletionError {
                Text(err)
            }
        }
        .alert("⚠️ Privileged Helper İzni Gerekiyor", isPresented: $viewModel.isWaitingForApproval) {
            Button("İzni Verdim, Tekrar Dene") {
                Task {
                    await viewModel.retryPendingDeletion()
                }
            }
            Button("Sistem Ayarlarını Aç") {
                viewModel.openSystemSettings()
            }
            Button("Vazgeç", role: .cancel) {
                viewModel.cancelPendingDeletion()
            }
        } message: {
            Text("Privileged Helper servisinin çalışabilmesi için macOS Sistem Ayarları > Giriş Öğeleri ve Uzantılar panelinden 'bunyamin.my-little-mac.helper' servisine izin verilmesi gerekmektedir.\n\nİzni verdikten sonra 'İzni Verdim, Tekrar Dene' butonuna tıklayınız.")
        }
    }

    // MARK: - Toolbar (macOS HIG Uyumlu)
    //
    // Yerleşim: Üç kontrol tek bir ToolbarItemGroup içinde, ortak yerel (glass) zemin
    // üzerinde bütünleşik bir grup olarak durur. Aralıklar NSToolbar tarafından yönetilir;
    // SwiftUI Divider() kullanılmaz (4.2).

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            advancedScanToolbarItem
            lockToggleToolbarItem
            helperStatusIndicator
        }
    }

    // MARK: - Toolbar Alt Bileşenleri

    /// 1. Gelişmiş Tarama Toggle'ı:
    /// Hover ile genişleme kaldırılmıştır (1.1, 1.2). İkon ve metin her zaman görünür;
    /// klavye ve VoiceOver kullanıcıları için etiket keşfedilebilirdir (1.3).
    /// Yerel `.button` toggle stili basılma, vurgulu (on) durum ve tema adaptasyonunu sağlar (4.4).
    private var advancedScanToolbarItem: some View {
        Toggle(isOn: $isAdvancedModeEnabled.animation(.easeInOut(duration: 0.25))) {
            Label("Gelişmiş Tarama", systemImage: "sparkles")
        }
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
        .disabled(viewModel.isBusy)
        .help("Gelişmiş Tarama (Team ID, BTM, System Extension) derin taramasını aç/kapat")
        .accessibilityHint("Team ID, BTM ve System Extension derin taramasını açar veya kapatır")
    }

    /// 2. Kilit Toggle'ı:
    /// • İkon sabit genişlikte bir kutuda durur; lock.fill / lock.open.fill glif farkı metni kaydırmaz (2.1).
    /// • Metin, tüm varyantların en genişine göre sabitlenir; kapsül genişliği zıplamaz (2.2).
    /// • Taranmış bir uygulama yokken veya işlem sürerken devre dışıdır (2.3, 4.3).
    private var lockToggleToolbarItem: some View {
        let isUnlocked = viewModel.isAdvancedModeUnlocked

        return Toggle(isOn: $viewModel.isAdvancedModeUnlocked.animation(.easeInOut(duration: 0.3))) {
            Label {
                StableWidthText(variants: ["Kilitli Dosyalar", "Kilit Açık"],
                                current: isUnlocked ? "Kilit Açık" : "Kilitli Dosyalar")
            } icon: {
                Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16, alignment: .center)
            }
        }
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
        .tint(.orange)
        .disabled(viewModel.scannedApp == nil || viewModel.isBusy)
        .help(isUnlocked
              ? "Kilitli dosyalar seçime açıldı — Kilitlemek için tıklayın"
              : "Kilitli riskli dosyaları seçime açmak için kilidi kaldırın")
        .accessibilityLabel("Kilitli dosyaları seçime aç")
        .accessibilityValue(isUnlocked ? "Kilit açık" : "Kilitli")
    }

    /// 3. Helper Durum Rozeti (Salt Okunur):
    /// Helper root yetkili bir XPC servisidir; durumu kullanıcı tarafından değiştirilemez (3.1).
    /// Metin genişliği tüm durum varyantlarına göre sabittir (3.2), renk ve metin geçişleri
    /// yumuşak biçimde interpolasyonla canlandırılır (3.3).
    private var helperStatusIndicator: some View {
        let status = viewModel.helperStatus

        return HStack(spacing: 6) {
            Circle()
                .fill(status.indicatorColor)
                .frame(width: 8, height: 8)

            StableWidthText(variants: HelperStatus.allCases.map(\.title),
                            current: status.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .fixedSize()
        .animation(.easeInOut(duration: 0.3), value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Privileged Helper durumu")
        .accessibilityValue(status.title)
        .help(status.helpText)
    }

    // MARK: - Header (Üst Kısım)

    private var headerSection: some View {
        VStack(spacing: 0) {
            if let app = viewModel.scannedApp {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.title2)
                                .fontWeight(.bold)

                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            Text("Toplam Seçili Boyut:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text(formattedSize(viewModel.totalSelectedSize))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(viewModel.totalSelectedSize > 0 ? Color.accentColor : Color.secondary)

                            Text("•")
                                .foregroundStyle(.tertiary)

                            Text("\(viewModel.selectedFiles.count) / \(app.relatedFiles.count) dosya seçildi")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Uygulama Değiştir Butonu
                    Button {
                        openAppSelectionPanel()
                    } label: {
                        Label("Uygulama Değiştir", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Giriş Ekranı (Minimal Main View: Drag & Drop + Buton)

    private var appSelectionArea: some View {
        VStack(spacing: 20) {
            Spacer()

            // ── Sürükle-Bırak Alanı ──
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                    )
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                    )

                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

                    VStack(spacing: 4) {
                        Text("Bir macOS uygulamasını (.app) buraya sürükleyin")
                            .font(.headline)
                            .foregroundStyle(isDropTargeted ? .primary : .secondary)

                        Text("veya diskten seçmek için butonu kullanın")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    // ── Uygulama Seç Butonu ──
                    Button {
                        openAppSelectionPanel()
                    } label: {
                        Label("Uygulama Seç", systemImage: "folder.badge.plus")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(32)
            }
            .frame(maxWidth: 520, minHeight: 240)
            .padding(.horizontal, 24)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File List (Akordeon DisclosureGroup Listesi & Kategori Checkbox'ı)

    private var fileListSection: some View {
        Group {
            if let error = viewModel.scanError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)

                    Text("Tarama Hatası")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)

                    Text(error)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.groupedFiles.isEmpty {
                ContentUnavailableView(
                    "Dosya Bulunamadı",
                    systemImage: "doc.questionmark",
                    description: Text("Taranacak bir uygulama seçin.")
                )
            } else {
                List {
                    ForEach(viewModel.groupedFiles, id: \.fileType) { group in
                        DisclosureGroup(isExpanded: isCategoryExpanded(group.fileType)) {
                            ForEach(group.files) { file in
                                FileRowView(
                                    file: file,
                                    isAdvancedModeUnlocked: viewModel.isAdvancedModeUnlocked,
                                    onToggle: { handleToggle(for: file) }
                                )
                            }
                        } label: {
                            HStack(spacing: 8) {
                                categoryIcon(for: group.fileType)

                                Text(group.fileType.rawValue)
                                    .font(.headline)
                                    .fontWeight(.semibold)

                                Spacer()

                                Text("\(group.files.count) öğe • \(formattedSize(group.files.reduce(0) { $0 + $1.size }))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                // Kategori "Tümünü Seç" Checkbox'ı (Mixed / Karma Durum Destekli)
                                MixedCheckboxView(
                                    state: categorySelectionState(for: group.files),
                                    onToggle: { toggleCategorySelection(for: group) }
                                )
                                .padding(.leading, 6)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Footer (Alt Kısım: Raporu Kaydet + Temizle/Simüle Et)

    private var footerSection: some View {
        HStack(spacing: 16) {
            // ── Raporu Kaydet (Audit Log Export) Butonu ──
            Menu {
                Button {
                    exportReportAsMarkdown()
                } label: {
                    Label("Markdown Raporu (.md)", systemImage: "doc.text")
                }

                if let logURL = viewModel.lastAuditLogURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    } label: {
                        Label("Son Denetim Günlüğü (.json)", systemImage: "doc.badge.gearshape")
                    }
                }

                Button {
                    viewModel.openLogsDirectory()
                } label: {
                    Label("Tüm Denetim Logları Klasörü", systemImage: "folder")
                }
            } label: {
                Label("Raporu Kaydet", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            } primaryAction: {
                exportReportAsMarkdown()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.scannedApp == nil)

            // ── Temizle / Simüle Et Butonu (UID 0 doğrulaması yoksa pasif) ──
            Button(action: {
                Task {
                    await viewModel.requestDeletion(files: viewModel.selectedFiles)
                }
            }) {
                if viewModel.isDeleting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Simüle Ediliyor…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Temizle / Simüle Et", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            // Helper bağlantısı yoksa işlem başlatıldığında otomatik kurulur ve root yetkisi
            // doğrulanır; UI Güvenlik Bariyeri requestDeletion içinde korunmaya devam eder.
            .disabled(viewModel.selectedFiles.isEmpty || viewModel.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Kategori ve Seçim Yönetimi (Karma / Mixed Durum & Güvenlik Bariyeri)

    /// Kategori içindeki öğelerin seçim durumunu tespit eder (.allSelected, .mixed, .noneSelected).
    private func categorySelectionState(for files: [ScannedFile]) -> CategorySelectionState {
        guard !files.isEmpty else { return .noneSelected }
        let selectedCount = files.filter { $0.isSelectedForDeletion }.count
        if selectedCount == 0 {
            return .noneSelected
        } else if selectedCount == files.count {
            return .allSelected
        } else {
            return .mixed
        }
    }

    /// Kategori başlığındaki checkbox'a tıklandığında güvenli seçim/kaldırma mantığı.
    /// KESİNLİKLE UI Güvenlik Bariyerini ezmez: Kilit kapalıysa yalnızca .safeToDelete olanlar seçilir!
    private func toggleCategorySelection(for group: (fileType: FileType, files: [ScannedFile])) {
        let state = categorySelectionState(for: group.files)

        // Deselect kararı:
        // 1. Kategori tamamen seçiliyse (.allSelected) -> tümünü kaldır
        // 2. Kilit kapalıyken tüm güvenli dosyalar zaten seçiliyse -> tümünü kaldır
        let shouldDeselect: Bool
        if state == .allSelected {
            shouldDeselect = true
        } else if state == .mixed && !viewModel.isAdvancedModeUnlocked {
            let safeFiles = group.files.filter { $0.riskLevel == .safeToDelete }
            let allSafeSelected = !safeFiles.isEmpty && safeFiles.allSatisfy { $0.isSelectedForDeletion }
            shouldDeselect = allSafeSelected
        } else {
            shouldDeselect = false
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            for file in group.files {
                guard let index = viewModel.scannedApp?.relatedFiles.firstIndex(where: { $0.id == file.id }) else { continue }
                if shouldDeselect {
                    viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = false
                } else {
                    // UI Güvenlik Bariyeri:
                    // Genel kilit kapalıysa, YALNIZCA .safeToDelete olanlar seçilebilir!
                    if viewModel.isAdvancedModeUnlocked {
                        viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = true
                    } else {
                        if file.riskLevel == .safeToDelete {
                            viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = true
                        } else {
                            viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = false
                        }
                    }
                }
            }
        }
    }

    private func isCategoryExpanded(_ fileType: FileType) -> Binding<Bool> {
        Binding(
            get: { !collapsedCategories.contains(fileType.rawValue) },
            set: { isExpanded in
                if isExpanded {
                    collapsedCategories.remove(fileType.rawValue)
                } else {
                    collapsedCategories.insert(fileType.rawValue)
                }
            }
        )
    }

    @ViewBuilder
    private func categoryIcon(for fileType: FileType) -> some View {
        switch fileType {
        case .appBundle:
            Image(systemName: "app.dashed")
                .foregroundStyle(.blue)
        case .cache:
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.purple)
        case .preference:
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.teal)
        case .launchDaemon:
            Image(systemName: "gearshape.2")
                .foregroundStyle(.orange)
        case .launchAgent:
            Image(systemName: "gearshape")
                .foregroundStyle(.orange)
        case .pkgReceipt:
            Image(systemName: "doc.badge.gearshape")
                .foregroundStyle(.brown)
        case .hiddenDotfile:
            Image(systemName: "eye.slash")
                .foregroundStyle(.gray)
        case .container:
            Image(systemName: "shippingbox")
                .foregroundStyle(.indigo)
        case .unknown:
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
        }
    }

    /// Toggle aksiyonunu risk seviyesine göre yönetir.
    private func handleToggle(for file: ScannedFile) {
        guard let index = fileIndex(for: file) else { return }

        // Seçim kaldırılıyorsa serbestçe kapat
        if file.isSelectedForDeletion {
            viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = false
            return
        }

        switch file.riskLevel {
        case .safeToDelete:
            viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = true

        case .sharedDependency, .unknown:
            if viewModel.isAdvancedModeUnlocked {
                sharedDependencyAlertFile = file
                showSharedDependencyAlert = true
            }

        case .highRisk:
            if viewModel.isAdvancedModeUnlocked {
                viewModel.scannedApp?.relatedFiles[index].isSelectedForDeletion = true
            }
        }
    }

    /// Dosyanın relatedFiles dizisindeki indeksini bulur.
    private func fileIndex(for file: ScannedFile) -> Int? {
        viewModel.scannedApp?.relatedFiles.firstIndex(where: { $0.id == file.id })
    }

    /// Bayt boyutunu okunabilir formata dönüştürür.
    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Rapor Dışa Aktarma

    /// Taranan tüm sonuçları detaylı bir Markdown (.md) dosyası olarak cihaza kaydeder.
    private func exportReportAsMarkdown() {
        guard let app = viewModel.scannedApp else { return }

        let reportText = MarkdownReportGenerator.generateReport(for: app)

        let savePanel = NSSavePanel()
        savePanel.title = "Tarama Raporunu Kaydet"
        savePanel.prompt = "Kaydet"

        let safeAppName = app.name.replacingOccurrences(of: " ", with: "_")
        savePanel.nameFieldStringValue = "\(safeAppName)_Tarama_Raporu.md"

        if let mdType = UTType(filenameExtension: "md") {
            savePanel.allowedContentTypes = [mdType]
        } else {
            savePanel.allowedContentTypes = [.plainText]
        }

        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            do {
                try reportText.write(to: destinationURL, atomically: true, encoding: .utf8)
                exportedFilePath = destinationURL.path
                showExportSuccessAlert = true
            } catch {
                viewModel.scanError = "Rapor kaydedilirken hata oluştu: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Uygulama Seçim ve Drop İşlemleri

    /// NSOpenPanel açarak kullanıcının /Applications dizininden sadece .app uzantılı paketleri seçmesine izin verir.
    private func openAppSelectionPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Uygulama Seç"
        panel.message = "Taranacak macOS uygulamasını (.app) seçin"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            guard selectedURL.pathExtension == "app" else { return }
            Task {
                await viewModel.startScan(
                    appUrl: selectedURL,
                    isAdvancedModeEnabled: isAdvancedModeEnabled
                )
            }
        }
    }

    /// Sürüklenen öğeleri kontrol eder ve SADECE .app ile biten paketleri kabul ederek taramayı başlatır.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url, url.pathExtension == "app" else { return }
            Task { @MainActor in
                await viewModel.startScan(
                    appUrl: url,
                    isAdvancedModeEnabled: isAdvancedModeEnabled
                )
            }
        }
        return true
    }
}

// MARK: - FileRowView (Akordeon Satır Görünümü & Hitbox)

struct FileRowView: View {
    let file: ScannedFile
    let isAdvancedModeUnlocked: Bool
    let onToggle: () -> Void

    @State private var isExpanded: Bool = false

    /// Dosyaların yanındaki Checkbox/Toggle bileşenlerinin pasiflik durumu:
    /// Dosya .safeToDelete DEĞİLSE ve isAdvancedModeUnlocked FALSE ise disabled(true) kalır.
    /// Kilit açıldığında Checkbox seçilebilir hale gelir.
    private var isToggleDisabled: Bool {
        return (file.riskLevel != .safeToDelete) && !isAdvancedModeUnlocked
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // ── Genişletilmiş İçerik ──
            VStack(alignment: .leading, spacing: 8) {
                // 1. Tam dosya yolu (path)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tam Dosya Yolu:")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 8) {
                        Text(file.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)

                        Spacer()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Yolu Kopyala")
                    }
                }

                Divider()

                // 2. Keşif yöntemi (discoveryMethod)
                HStack(spacing: 6) {
                    Text("Keşif Yöntemi:")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Text(discoveryMethodTitle(file.discoveryMethod))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // 3. Güvenlik Gerekçesi
                if let reasoning = file.reasoningText, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Güvenlik Gerekçesi:")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Text(reasoning)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .padding(.vertical, 4)
        } label: {
            // ── Ana Satır: Güvenlik İkonu, Dosya Adı, Boyut ve Büyük Checkbox ──
            HStack(spacing: 10) {
                // Güvenlik / Risk İkonu
                riskIcon

                // Dosya / Klasör Adı
                Text(file.url.lastPathComponent)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Boyut
                Text(formattedSize(file.size))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // En sağda büyük bir Checkbox
                Toggle("", isOn: Binding(
                    get: { file.isSelectedForDeletion },
                    set: { _ in
                        if !isToggleDisabled {
                            onToggle()
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.regular)
                .disabled(isToggleDisabled)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle()) // KESİNLİKLE satırın tamamını tıklanabilir (hitbox) yapar
            .onTapGesture {
                if !isToggleDisabled {
                    onToggle()
                }
            }
        }
        .opacity(isToggleDisabled ? 0.65 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: isAdvancedModeUnlocked)
    }

    private func discoveryMethodTitle(_ method: DiscoveryMethod) -> String {
        switch method {
        case .standard:
            return "Standart Dizin Taraması"
        case .spotlight:
            return "Spotlight Metadata (mdfind)"
        case .pkgutil:
            return "macOS PKG Makbuz & BOM Analizi (pkgutil)"
        case .teamID:
            return "Apple Developer Team ID Group Container"
        case .btm:
            return "Background Task Management (BTM Kaydı)"
        case .extension:
            return "macOS System Extension"
        case .heuristic:
            return "Sezgisel Heuristic Analiz"
        case .heuristicOverride:
            return "Heuristic Özel Kural Override"
        }
    }

    // MARK: - Risk İkonu (SF Symbols)

    @ViewBuilder
    private var riskIcon: some View {
        switch file.riskLevel {
        case .safeToDelete:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.system(size: 15))
                .help("Güvenli: Doğrudan uygulamaya ait, silinmesi güvenlidir.")

        case .sharedDependency:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))
                .help("Paylaşılan Bağımlılık: Ortak kütüphane veya araç klasörü. Kilitlidir.")

        case .highRisk:
            Image(systemName: "shield.slash.fill")
                .foregroundStyle(.red)
                .font(.system(size: 15))
                .help("Yüksek Risk: Sistem veya kök dizin dosyası. Kilitlidir.")

        case .unknown:
            Image(systemName: "questionmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))
                .help("Bilinmeyen: Tanımlanamayan dotfile veya vendor yapısı. Kilitlidir.")
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
