//
//  MarkdownReportGenerator.swift
//  my_little_mac
//
//  Tarama sonuçlarını açık, net ve detaylı bir Markdown (.md) raporuna dönüştürür.
//

import Foundation

struct MarkdownReportGenerator {
    
    /// Verilen ScannedApp nesnesindeki tüm tarama verilerini Markdown formatına döker.
    static func generateReport(for app: ScannedApp) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let totalFilesCount = app.relatedFiles.count
        let totalBytes = app.relatedFiles.reduce(0) { $0 + $1.size }
        let selectedFiles = app.relatedFiles.filter { $0.isSelectedForDeletion }
        let selectedBytes = selectedFiles.reduce(0) { $0 + $1.size }
        
        var md = ""
        md += "# macOS Uygulama Kalıntı Tarama Raporu\n\n"
        
        // 1. Hedef Uygulama Bilgileri
        md += "## 1. Hedef Uygulama Bilgileri\n\n"
        md += "- **Uygulama Adı:** \(app.name)\n"
        md += "- **Bundle Identifier:** `\(app.bundleIdentifier)`\n"
        md += "- **Uygulama Dosya Yolu:** `\(app.mainAppUrl.path)`\n"
        md += "- **Tarama Tarihi:** \(timestamp)\n"
        md += "- **Toplam Bulunan Öğe Sayısı:** \(totalFilesCount)\n"
        md += "- **Toplam Boyut:** \(formatBytes(totalBytes)) (\(totalBytes) Bayt)\n"
        md += "- **Seçili Öğe Sayısı:** \(selectedFiles.count)\n"
        md += "- **Seçili Boyut:** \(formatBytes(selectedBytes)) (\(selectedBytes) Bayt)\n\n"
        
        // 2. Kategori Bazlı Özet Tablosu
        md += "## 2. Kategori Özeti\n\n"
        md += "| Dosya Türü | Öğe Sayısı | Toplam Boyut | Seçili Boyut |\n"
        md += "|---|---|---|---|\n"
        
        let grouped = Dictionary(grouping: app.relatedFiles) { $0.fileType }
        let sortedGroupKeys = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        
        for fileType in sortedGroupKeys {
            let files = grouped[fileType] ?? []
            let count = files.count
            let catTotalBytes = files.reduce(0) { $0 + $1.size }
            let catSelectedBytes = files.filter { $0.isSelectedForDeletion }.reduce(0) { $0 + $1.size }
            md += "| \(fileType.rawValue) | \(count) | \(formatBytes(catTotalBytes)) | \(formatBytes(catSelectedBytes)) |\n"
        }
        md += "\n"
        
        // 3. Risk Seviyesi Dağılımı
        md += "## 3. Risk Seviyesi Dağılımı\n\n"
        md += "| Risk Seviyesi | Kod | Açıklama | Öğe Sayısı |\n"
        md += "|---|---|---|---|\n"
        
        let riskGroups = Dictionary(grouping: app.relatedFiles) { $0.riskLevel }
        let allRisks: [RiskLevel] = [.safeToDelete, .sharedDependency, .highRisk, .unknown]
        for risk in allRisks {
            let count = riskGroups[risk]?.count ?? 0
            md += "| \(riskTitle(risk)) | `\(risk.rawValue)` | \(riskDescription(risk)) | \(count) |\n"
        }
        md += "\n"
        
        // 4. Detaylı Dosya ve Dizin Listesi
        md += "## 4. Taranan Dosya ve Klasörlerin Tam Listesi\n\n"
        
        for fileType in sortedGroupKeys {
            let files = grouped[fileType] ?? []
            let catTotalBytes = files.reduce(0) { $0 + $1.size }
            md += "### \(fileType.rawValue) (\(files.count) öğe - \(formatBytes(catTotalBytes)))\n\n"
            
            for (index, file) in files.enumerated() {
                let statusText = file.isSelectedForDeletion ? "[X] (SEÇİLİ)" : "[ ] (SEÇİLİ DEĞİL)"
                md += "#### \(index + 1). `\(file.url.lastPathComponent)`\n"
                md += "- **Tam Fiziksel Yol:** `\(file.url.path)`\n"
                md += "- **Boyut:** \(formatBytes(file.size)) (\(file.size) Bayt)\n"
                md += "- **Dosya Türü:** \(file.fileType.rawValue)\n"
                md += "- **Risk Seviyesi:** \(riskTitle(file.riskLevel)) (Kod: \(file.riskLevel.rawValue))\n"
                md += "- **Silme Seçim Durumu:** \(statusText)\n"
                if let bundleID = file.relatedBundleID {
                    md += "- **İlişkili Bundle ID:** `\(bundleID)`\n"
                }
                md += "\n"
            }
        }
        
        return md
    }
    
    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private static func riskTitle(_ risk: RiskLevel) -> String {
        switch risk {
        case .safeToDelete:
            return "safeToDelete"
        case .sharedDependency:
            return "sharedDependency"
        case .highRisk:
            return "highRisk"
        case .unknown:
            return "unknown"
        }
    }
    
    private static func riskDescription(_ risk: RiskLevel) -> String {
        switch risk {
        case .safeToDelete:
            return "Güvenli (Mutlak sahiplik kanıtı var)"
        case .sharedDependency:
            return "Paylaşılan Bağımlılık (Başka uygulamalarla ortak)"
        case .highRisk:
            return "Yüksek Risk (Kök dizin, dotfile, korumalı)"
        case .unknown:
            return "Bilinmeyen (Analiz edilemedi / doğrulanmadı)"
        }
    }
}
