# my_little_mac - macOS App Uninstaller & Cleaner

Bu proje, macOS uygulamalarını ve sistemde bıraktıkları kalıntı dosyaları tespit etmek için geliştirilmiş, salt-okunur (read-only) ve güvenlik odaklı bir sistem aracıdır. SwiftUI ile geliştirilmiş olup, yapay zeka ajanlarının (Antigravity IDE) halüsinasyon görmesini ve sisteme zarar vermesini engelleyen katı "Tahribat Engeli" ve "UI Güvenlik Bariyeri" kuralları çerçevesinde inşa edilmiştir.

## ⚠️ Mevcut Durum: Gözlem Modu (Read-Only)
Proje şu anda **MVP (Minimum Viable Product)** aşamasındadır. Dosya silme (`rm -rf`, `FileManager.removeItem`) işlemleri XPC katmanında kasıtlı olarak devre dışı bırakılmıştır (Dummy mode). Uygulama sadece tarar, risk analizi yapar ve raporlar. Sistemde fiziksel bir değişiklik yapmaz.

## Mimari ve Güvenlik Protokolleri

Sistem, hatalı silmeleri ve sistem çökmelerini önlemek için katı bir Risk Analiz (RiskLevel) mimarisi kullanır:

1. **.safeToDelete (Güvenli):** Hedef uygulamanın Bundle ID'si ile mutlak eşleşen önbellek (cache) ve ayar (preference) dosyaları. Arayüzde seçilebilir durumdadır.
2. **.sharedDependency (Paylaşılan Bağımlılık):** Birden fazla uygulama tarafından ortak kullanıldığı tespit edilen dosyalar (Örn: Ortak kütüphaneler). UI'da kilitli ve seçimsiz başlatılır.
3. **.highRisk (Yüksek Risk):** macOS kök dizinleri veya emin olunamayan yapılandırma dosyaları. Kilitlidir, kullanıcının manuel onayını gerektirir.
4. **.unknown (Bilinmeyen):** Analiz edilemeyen tüm vendor ve dotfile yapıları. Varsayılan olarak kapalıdır.

## Tarama Yetenekleri (Mevcut Algoritmalar)

- **Spotlight (mdfind) Entegrasyonu:** `kMDItemCFBundleIdentifier` üzerinden metadata taraması.
- **Derin Fallback Taraması:** `~/Library` altındaki `Application Support`, `Caches`, `Preferences`, `Containers`, `WebKit`, `HTTPStorages` ve `Application Scripts` dizinlerinin taranması.
- **Darwin Cache & Temp Tespiti:** macOS'in `getconf DARWIN_USER_CACHE_DIR` ile oluşturduğu, Spotlight'ın indekslemediği özel dinamik önbelleklerin tespiti.
- **Vendor (Üretici) Katmanı Taraması:** Uygulamaların üretici adıyla (Örn: `Riot Games/League of Legends`) iç içe açtığı gizli destek klasörlerinin ayrıştırılması.
- **App Extension Tespit:** Ana Bundle ID'den türetilen `.FinderOpen`, `.ShareExtension` gibi yan eklentilerin kapsanması.

## Kurulum ve Test (Geliştiriciler İçin)

macOS Sandbox (Korumalı Alan) kısıtlamaları nedeniyle uygulamanın derin sistem taraması yapabilmesi için Tam Disk Erişimi (Full Disk Access) yetkisine ihtiyacı vardır.

1. Projeyi Xcode'da açın.
2. `Signing & Capabilities` sekmesinden **App Sandbox**'ı devre dışı bırakın.
3. Derleyip çalıştırın.
4. `Sistem Ayarları -> Gizlilik ve Güvenlik -> Tam Disk Erişimi` menüsünden derlenen uygulamaya yetki verin.

## Gelecek Yol Haritası (Advanced Protocols)
- [ ] Heuristic Rules Database (JSON) Entegrasyonu
- [ ] Apple Developer Team ID bazlı `Group Containers` Taraması
- [ ] BTM (Background Task Management) arka plan görevleri dökümü
- [ ] PKG makbuz (receipt) analizi ve XPC Privileged Helper Tool aktivasyonu.