---
description: "Advanced Discovery Protocols for Deep macOS Cleaning (Passive Rules)"
alwaysOn: false
---

@[SharedModel](shared_model.md)

# SYSTEM DIRECTIVE: ADVANCED PROTOCOLS
Sen bir Antigravity ajanı değilsin, tarama ajanlarına (Scanner) yön verecek olan pasif bir kural setisin. Eğer Scanner ajanı `isAdvancedModeEnabled` bayrağı ile tetiklenirse, standart aramalara ek olarak aşağıdaki 4 spesifik vektörü tarama motoruna eklemek zorundadır.

## 1. MUTLAK KISITLAMALAR (TAHRİBAT ENGELİ & UI BARIYERİ)
- Hiçbir koşulda `rm -rf`, `removeItem(at:)` veya türevi dosya silme komutları kullanma. Kod sadece sistemden okuyacak, yolları parse edecek ve listeleyecektir.
- Bu anayasadan elde edilen tüm dosyalar, macOS çekirdeğine veya ortak uygulamalara zarar verme riski taşıdığı için UI Güvenlik Bariyeri gereği kesinlikle `isSelectedForDeletion = false` (Seçilmemiş) olarak başlatılacaktır.
- Çıktı sadece ve sadece `[ScannedFile]` dizisine dahil edilecektir.

## 2. DİNAMİK VEKTÖR: TEAM ID & GROUP CONTAINERS
- Hedef `.app` paketinin kod imzasını `codesign -dv --verbose=4 <app_path>` komutuyla (Process) veya `Info.plist` üzerinden oku ve 'TeamIdentifier' değerini (Örn: `EQHXZ8M8AV`) çıkar.
- `FileManager` kullanarak SADECE `~/Library/Group Containers/` dizinini tara. Eğer klasör adı bu Team ID ile başlıyorsa, bu yolu listeye ekle.
- ZORUNLU DEĞERLER: `fileType: .container`, `riskLevel: .sharedDependency`, `discoveryMethod: .teamID`. (Sebebini Analyzer yorumlayacaktır).

## 3. DİNAMİK VEKTÖR: BTM (BACKGROUND TASK MANAGEMENT)
- `Process` kullanarak asenkron olarak `sfltool dumpbtm` komutunu çalıştır.
- Çıktıyı parse et. Eğer bir satır hedef uygulamanın `CFBundleIdentifier`'ını içeriyorsa, o bloğa ait `URL` veya `path` değerini ayıkla.
- ZORUNLU DEĞERLER: `riskLevel: .highRisk`, `discoveryMethod: .btm`.

## 4. DİNAMİK VEKTÖR: SYSTEM EXTENSIONS
- `Process` kullanarak `systemextensionsctl list` komutunu çalıştır.
- Çıktıda hedef Bundle ID ile eşleşen bir sistem eklentisi (kext/dext) varsa, ilgili yolu tespit et.
- ZORUNLU DEĞERLER: `riskLevel: .highRisk`, `discoveryMethod: .extension`.

## 5. STATİK VEKTÖR: HEURISTIC DATABASE
- Projenin `Resources` dizini içinde (veya projenin statik dosyası olarak) yer alan `heuristics.json` dosyasını oku. (Dosya yoksa boş kabul et).
- JSON formatı `[String: [String]]` şeklindedir (Key: Hedef .app dosya adı token'ı, Value: Path listesi). Anahtar (Key) CFBundleIdentifier DEĞİL, hedefin .app dosya adının uzantısız, boşlukları tireye çevrilmiş ve tamamen küçük harf yapılmış halidir (Örn: "Google Chrome.app" -> "google-chrome").
- JSON'dan dönen yollarda bulunan `~` karakterini `(NSHomeDirectory() as NSString)` ile mutlak fiziksel yola çevir. Yalnızca bu tam fiziksel yolda dosya bulunursa `[ScannedFile]` dizisine ekle.
- ZORUNLU DEĞERLER: `riskLevel: .unknown`, `discoveryMethod: .heuristic`, `isSelectedForDeletion = false`.

## 6. STATİK VEKTÖR: HEURISTIC OVERRIDES (SPESİFİK ALT KLASÖRLER)
- Projenin `Resources` dizini içinde (veya projenin statik dosyası olarak) yer alan `overrides.json` dosyasını oku. (Dosya yoksa boş kabul et).
- JSON formatı `[String: [String]]` şeklindedir (Key: Bundle ID, Value: Alt klasör yolları).
- JSON'dan dönen yollarda bulunan `~` karakterini `(NSHomeDirectory() as NSString)` ile mutlak fiziksel yola çevir. Yalnızca bu tam fiziksel yolda dosya bulunursa `[ScannedFile]` dizisine ekle.
- ZORUNLU DEĞERLER: `riskLevel: .safeToDelete`, `discoveryMethod: .heuristicOverride`, `isSelectedForDeletion = true`.
- İZOLASYON & DEDUPLICATION: Eğer overrides.json üzerinden .heuristicOverride ile bulunmuş spesifik alt dosyalar varsa ve bu alt dosyaların üst klasörü (Parent) listede yer alıyorsa; üst klasörün `riskLevel` değeri KESİNLİKLE `.highRisk` (Kod: 2) olarak zorlanır ve `isSelectedForDeletion = false` yapılır.
- UI GÜVENLİK BARİYERİ: `[ScannedFile]` içindeki `riskLevel` değeri `.safeToDelete` olmayan HİÇBİR klasör varsayılan olarak seçili (`true`) başlatılamaz. Override katmanı bu kuralı delemez.
