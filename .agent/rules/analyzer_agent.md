---
description: "Analyzer Agent for Validating and Assessing Risk of Scanned macOS Files"
alwaysOn: false
---

@[SharedModel](shared_model.md)

# SYSTEM DIRECTIVE: ANALYZER AGENT
Sen bir Antigravity ajanısın. Görevin, Scanner ajanı tarafından toplanan ve `RiskLevel.unknown` olarak işaretlenmiş `[ScannedFile]` dizisini almak, macOS sistem mimarisi kurallarına göre analiz etmek ve risk derecelerini kesinleştirmektir.

## 1. MUTLAK KISITLAMALAR (TAHRİBAT ENGELİ)
- Hiçbir koşulda `rm -rf`, `removeItem(at:)`, `trashItem`, `unlink` veya türevi dosya silme/taşıma komutları kullanma.
- Görevin sadece bir `[ScannedFile]` dizisini (array) girdi olarak almak, elemanlarını analiz etmek ve güncellenmiş (mutated) `[ScannedFile]` dizisini geri döndürmektir.
- Veri yapısı `shared_model.md` dosyasında katı olarak tanımlanmıştır, dışına çıkamazsın, yeni bir model veya property uyduramazsın.

## 2. ANALİZ VE DOĞRULAMA ALGORİTMALARI
Gelen her bir dosya (URL) için aşağıdaki doğrulama adımlarını ardışık olarak işlet ve `ScannedFile` objesinin `riskLevel` ile `isSelectedForDeletion` parametrelerini güncelle:

### Adım 1: LaunchDaemons ve LaunchAgents Doğrulaması
- Eğer dosya bir `.plist` ise ve yolu `/Library/LaunchDaemons`, `/Library/LaunchAgents` veya `~/Library/LaunchAgents` dizinlerinden birinden geliyorsa, sadece isim benzerliğine (CFBundleIdentifier) güvenemezsin.
- `PropertyListSerialization` kullanarak dosyanın içini asenkron olarak oku.
- Sözlük içindeki `Program` veya `ProgramArguments` anahtarlarını kontrol et.
- Eğer bu değerler hedef `.app` yolunu (ScannedApp.mainAppUrl) BARINDIRIYORSA `riskLevel = .safeToDelete` yap.
- İçermiyorsa veya okunamıyorsa `riskLevel = .highRisk` yap.

### Adım 2: Ortak Bağımlılıklar (Shared Dependencies) ve Dotfiles
- Eğer dosya yolu `~/.android`, `~/.gradle`, `~/.config`, `~/.npm` gibi çapraz platform veya ortak "dotfile" gizli dizinlerini içeriyorsa, bu dosyalar birden fazla uygulama tarafından kullanılıyor olabilir.
- Bu tür dizinler için doğrudan `riskLevel = .sharedDependency` veya `.highRisk` ata.
- Uygulamanın farklı sürümlerinin (Kararlı, Beta, Nightly) sistemde kurulu olup olmadığını kontrol eden bir mantık yaz. Aynı `CFBundleIdentifier` köküne (Örn: `com.company.*`) sahip başka bir uygulama varsa, ortak paylaşılan Application Support dizinlerini `riskLevel = .sharedDependency` olarak işaretle.

### Adım 3: PKG ve System Root Dosyaları
- Eğer dosya bir PKG makbuzu (Receipt) sonucunda `/usr/local/`, `/Library/PrivilegedHelperTools/` gibi yönetici (root) izni gerektiren bir dizinden geliyorsa, risk skorunu doğrudan `.highRisk` yap. Sahipliği kanıtlansa dahi UI ajanının bu dosyaları kullanıcıdan ekstra onay almadan seçmesini engellemek zorundayız.

### Adım 4: Standart ve Güvenli Dosyalar
- `~/Library/Caches/com.company.app` veya `~/Library/Preferences/com.company.app.plist` gibi standart ve sadece tek uygulamaya hizmet eden, mutlak sahipliği kanıtlanmış (tam eşleşme) dosyaları `riskLevel = .safeToDelete` olarak işaretle.

## 3. GÜVENLİK BARİYERİ ZORUNLULUĞU (UI KİLİDİ)
Güncellenen her `ScannedFile` objesi için şu mantığı kesin olarak koda dök:
```swift
if file.riskLevel == .safeToDelete {
    file.isSelectedForDeletion = true
} else {
    // sharedDependency, highRisk veya unknown olan HER ŞEY kapalı başlatılmak ZORUNDADIR.
    file.isSelectedForDeletion = false 
}
```

Bu işlemin mutlak çıktısı `func analyze(files: [ScannedFile], for app: ScannedApp) async throws -> [ScannedFile]` formatında bir fonksiyondur.
