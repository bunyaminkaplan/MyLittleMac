---
description: "Core Data Models and Risk Assessment Constitution for macOS Cleaner"
alwaysOn: false
---

# SYSTEM DIRECTIVE: STRICT DATA PROTOCOL
Sen bir Antigravity ajanısın. Bu dosya, projede kullanacağın tüm Swift veri yapılarının mutlak anayasasıdır. Kendi veri modellerini (struct/class) uyduramazsın, buradaki isimlendirmeleri ve veri tiplerini DEĞİŞTİREMEZSİN.

## 1. TAHRIBAT ENGELİ VE MUTLAK YASAKLAR
- Hiçbir koşulda `rm -rf`, `removeItem(at:)`, `trashItem` veya türevi dosya silme/taşıma komutları kullanma. Bu proje sadece bulacak, doğrulayacak ve listeleyecektir.
- Model yapılarında değişiklik yapmak, projeyi derlenemez hale getirir. Tip güvenliğine (type safety) mutlak sadakat göster.

## 2. SWIFT DATA MODELS (ZORUNLU KULLANIM)

### A. RiskLevel (Enum)
macOS sistem dosyalarına zarar vermemek için risk seviyesi paranoyak bir şekilde sınıflandırılmalıdır. Arayüz bu seviyelere göre dosyaları kilitleyecektir.

```swift
enum RiskLevel: Int, Codable {
    case safeToDelete = 0 // Mutlak sahiplik kanıtı var (CFBundleIdentifier eşleşmesi tam)
    case sharedDependency = 1 // Aynı bundle ID ailesinden başka uygulamalar (Kararlı/Beta) ile ortak kullanılıyor. SİLİNEMEZ.
    case highRisk = 2 // Kök dizin, dotfile (~/.config, vs.) veya emin olunamayan LaunchDaemons dosyası. UI'da SEÇİLEMEZ.
    case unknown = 3 // Analiz edilemedi, varsayılan olarak dokunulmaz.
}
```

### B. FileType (Enum)
Dosyanın sistemdeki işlevini ve yerini belirtir.

```swift
enum FileType: String, Codable {
    case appBundle = "App Bundle"
    case launchDaemon = "Launch Daemon"
    case launchAgent = "Launch Agent"
    case cache = "Cache"
    case preference = "Preference"
    case pkgReceipt = "PKG Receipt File"
    case hiddenDotfile = "Hidden Dotfile"
    case unknown = "Unknown"
}
```

### C. ScannedFile (Struct)
Bulunan her bir dosyanın veya klasörün temsilidir. Scanner ve Analyzer bu nesneyi üretir, UI sadece bu nesneyi okur.

```swift
struct ScannedFile: Identifiable, Equatable {
    let id: UUID
    let url: URL // Dosyanın tam fiziksel yolu
    let size: Int64 // Bayt cinsinden boyut
    let fileType: FileType
    let riskLevel: RiskLevel
    let relatedBundleID: String? // Dosyanın kime ait olduğunun CFBundleIdentifier kanıtı
    var isSelectedForDeletion: Bool // UI ajanının kullanacağı seçim durumu. RiskLevel 1, 2 veya 3 ise bu değer ZORUNLU OLARAK false başlatılmalıdır.
}
```

### D. ScannedApp (Struct)
Kaldırılmak üzere seçilen ana hedef uygulamayı temsil eder.

```swift
struct ScannedApp: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String // Taramaların temelini oluşturacak mutlak ID
    let name: String
    let mainAppUrl: URL
    var relatedFiles: [ScannedFile] // Uygulamaya ait bulunan yan dosyalar
}
```

## 3. İLETİŞİM PROTOKOLÜ
Ajanlar arası iletişim bu modeller üzerinden sağlanacaktır. Scanner ajanı `[ScannedFile]` dizisi oluşturacak, Analyzer ajanı bu dizideki elemanların `riskLevel` değerlerini güncelleyecek, UI ajanı ise `isSelectedForDeletion` değerine `riskLevel` üzerinden müdahale ederek ekrana çizecektir.
