//
//  ContentView.swift
//  my_little_mac
//
//  Created by Bünyamin Kaplan on 12.10.2026.
//
//  UI Agent: Analyzer'dan gelen risk skorlu [ScannedFile] listesini ekrana çizer.
//  Silme kodu İÇERMEZ. Sadece state gösterir ve isSelectedForDeletion yönetir.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    private let scannerService = ScannerService()
    private let analyzerService = AnalyzerService()
    private let xpcConnectionManager = XPCConnectionManager()

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

    // MARK: - XPC IPC Köprü Metodu (UI & İletişim Bariyeri)

    /// SADECE `isSelectedForDeletion == true` olan [ScannedFile] objelerinin mutlak fiziksel yollarını (`[String]`)
    /// filtreleyip XPC servisine gönderen köprü metodu.
    /// Kilitli (seçilmemiş) hiçbir dosya yolu KESİNLİKLE IPC üzerinden Helper'a iletilemez.
    @MainActor
    func requestDeletion(files: [ScannedFile]) async {
        // İletişim Bariyeri: Yalnızca isSelectedForDeletion == true olanların mutlak path'lerini filtrele
        let approvedPaths: [String] = files
            .filter { $0.isSelectedForDeletion }
            .map { $0.url.standardizedFileURL.path }

        // Kilitli / seçilmemiş hiçbir dosya yolu iletilemez; liste boşsa durdur
        guard !approvedPaths.isEmpty else {
            return
        }

        isDeleting = true
        deletionError = nil
        deletionSuccessMessage = nil

        do {
            let success = try await xpcConnectionManager.verifyAndPrepareDeletion(paths: approvedPaths)
            if success {
                deletionSuccessMessage = "\(approvedPaths.count) dosya yolu Privileged Helper tarafından doğrulandı ve hazırlandı (simülasyon)."
            }
        } catch {
            deletionError = error.localizedDescription
        }

        isDeleting = false
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
            // Adım 1: ScannerService ile tarama (isAdvancedModeEnabled parametresiyle)
            let scannedFiles = try await scannerService.scan(
                appUrl: app.mainAppUrl,
                isAdvancedModeEnabled: isAdvancedModeEnabled
            )

            // Adım 2: AnalyzerService ile risk analizi
            let analyzedFiles = try await analyzerService.analyze(files: scannedFiles, for: app)

            // Analiz sonuçlarını ScannedApp'e yerleştir
            app.relatedFiles = analyzedFiles

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

// MARK: - ContentView

struct ContentView: View {
    @State private var viewModel = ContentViewModel()
    @AppStorage("isAdvancedModeEnabled") private var isAdvancedModeEnabled: Bool = false
    @State private var showSharedDependencyAlert = false
    @State private var sharedDependencyAlertFile: ScannedFile?
    @State private var isDropTargeted = false
    @State private var showExportSuccessAlert = false
    @State private var exportedFilePath = ""

    var body: some View {
        VStack(spacing: 0) {
            // ── Üst Kısım: Uygulama Adı ve Toplam Seçili Boyut ──
            headerSection

            Divider()

            // ── Liste: FileType'a göre gruplandırılmış dosyalar ──
            fileListSection

            Divider()

            // ── Alt Kısım: Temizle Butonu ──
            footerSection
        }
        .frame(minWidth: 600, minHeight: 500)
        .alert(
            "⚠️ Paylaşılan Bağımlılık",
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
            Text("Bu dosya başka uygulamalar tarafından kullanılıyor olabilir. Silinmesi sistem kararlılığını etkileyebilir.")
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
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            if viewModel.isScanning {
                // ── Tarama Devam Ediyor ──
                ProgressView("Taranıyor…")
                    .progressViewStyle(.circular)
                    .padding()
            } else if let app = viewModel.scannedApp {
                // ── Uygulama Tarandı ──
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Seçili Boyut: \(formattedSize(viewModel.totalSelectedSize))")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        // Gelişmiş Tarama Toggle
                        Toggle(isOn: $isAdvancedModeEnabled) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.purple)
                                Text("Gelişmiş Tarama")
                                    .font(.caption)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .onChange(of: isAdvancedModeEnabled) { _, newValue in
                            Task { @MainActor in
                                await viewModel.startScan(
                                    appUrl: app.mainAppUrl,
                                    isAdvancedModeEnabled: newValue
                                )
                            }
                        }

                        // Raporu Kaydet butonu (.md)
                        Button {
                            exportReportAsMarkdown()
                        } label: {
                            Label("Raporu Kaydet (.md)", systemImage: "arrow.down.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)

                        // Yeni uygulama seçmek için küçük buton
                        Button {
                            openAppSelectionPanel()
                        } label: {
                            Label("Değiştir", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            } else {
                // ── Uygulama Seçilmedi: Drop Zone + Buton ──
                appSelectionArea
            }
        }
    }

    // MARK: - App Selection Area (Drop Zone + Buton)

    private var appSelectionArea: some View {
        VStack(spacing: 16) {
            // ── Drop Zone ──
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                    )
                    .foregroundStyle(isDropTargeted ? .blue : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isDropTargeted ? Color.blue.opacity(0.08) : Color.clear)
                    )

                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(isDropTargeted ? .blue : .secondary)

                    Text("Bir .app dosyasını buraya sürükleyin")
                        .font(.headline)
                        .foregroundStyle(isDropTargeted ? .primary : .secondary)

                    Text("veya")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

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
            }
            .frame(height: 220)
            .padding(.horizontal, 24)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            // ── Gelişmiş Tarama Toggle ──
            Toggle(isOn: $isAdvancedModeEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Gelişmiş Tarama (Team ID, BTM, Extensions)")
                        .fontWeight(.medium)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - File List

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
                        Section(header: Text(group.fileType.rawValue)) {
                            ForEach(group.files) { file in
                                FileRowView(
                                    file: file,
                                    isAdvancedModeUnlocked: viewModel.isAdvancedModeUnlocked,
                                    onToggle: { handleToggle(for: file) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 12) {
            // Advanced Mode Toggle — kilitli dosyaları seçime açar
            Toggle(isOn: $viewModel.isAdvancedModeUnlocked) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isAdvancedModeUnlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Kilitli Dosyaları Seçime Aç")
                        .font(.caption)
                }
            }
            .toggleStyle(.checkbox)

            Button(action: {
                Task {
                    await viewModel.requestDeletion(files: viewModel.selectedFiles)
                }
            }) {
                if viewModel.isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Seçilenleri Temizle", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.selectedFiles.isEmpty || viewModel.isDeleting)
        }
        .padding()
    }

    // MARK: - Yardımcılar

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
        
        // Örn: AndroidStudio_Tarama_Raporu.md
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

// MARK: - FileRowView

struct FileRowView: View {
    let file: ScannedFile
    let isAdvancedModeUnlocked: Bool
    let onToggle: () -> Void

    /// Dosyaların yanındaki Checkbox/Toggle bileşenlerinin .disabled() modifier'ı:
    /// Sadece dosya .safeToDelete DEĞİLSE ve isAdvancedModeUnlocked FALSE ise disabled(true) olmalıdır.
    /// Kilit açıldığında hiçbir Checkbox kilitli kalmamalıdır.
    private var isToggleDisabled: Bool {
        return (file.riskLevel != .safeToDelete) && !isAdvancedModeUnlocked
    }

    var body: some View {
        HStack(spacing: 12) {
            // Risk ikonu
            riskIcon

            // Dosya bilgileri
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Keşif yöntemi ve Analyzer gerekçesi (.caption, .secondary)
                HStack(spacing: 4) {
                    Text(discoveryMethodTitle(file.discoveryMethod))
                    if let reasoning = file.reasoningText, !reasoning.isEmpty {
                        Text("•")
                        Text(reasoning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(formattedSize(file.size))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Checkbox / Toggle butonu
            Toggle("", isOn: Binding(
                get: { file.isSelectedForDeletion },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isToggleDisabled)
        }
        .padding(.vertical, 4)
        .opacity(isToggleDisabled ? 0.6 : 1.0)
    }

    private func discoveryMethodTitle(_ method: DiscoveryMethod) -> String {
        switch method {
        case .standard:
            return "Keşif: Standart Tarama"
        case .teamID:
            return "Keşif: Team ID Paylaşımı"
        case .btm:
            return "Keşif: BTM (Background Task)"
        case .extension:
            return "Keşif: System Extension"
        case .heuristic:
            return "Keşif: Heuristic Kuralı"
        case .heuristicOverride:
            return "Keşif: Heuristic Override"
        }
    }

    // MARK: - Risk İkonu

    @ViewBuilder
    private var riskIcon: some View {
        switch file.riskLevel {
        case .safeToDelete:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .help("Güvenli — silinebilir")

        case .sharedDependency:
            Text("⚠️")
                .help("Paylaşılan bağımlılık — başka uygulamalar kullanıyor olabilir")

        case .highRisk:
            Text("🛑")
                .help("Yüksek risk — sistem dosyası olabilir")

        case .unknown:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.gray)
                .help("Bilinmeyen — analiz edilemedi")
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
