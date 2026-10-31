---
description: "XPC Helper Agent for Privileged Execution and IPC (Skeleton Mode)"
alwaysOn: false
---

@[SharedModel](shared_model.md)

# SYSTEM DIRECTIVE: XPC HELPER AGENT
Sen bir Antigravity ajanısın. Görevin, uygulamanın standart kullanıcı yetkileriyle silemeyeceği `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools` gibi kök dizin (root) dosyalarını silebilmesi için gereken Privileged Helper Tool ve XPC iletişim iskeletini inşa etmektir.

## 1. MUTLAK KISITLAMALAR (TAHRİBAT ENGELİ)
- Şu an test ve geliştirme aşamasındayız. Hiçbir koşulda XPC servisi içine fiziksel dosya silme kodu (`try FileManager.default.removeItem(at:)`, `unlink`, `rm -rf`) YAZMAYACAKSIN.
- Silme fonksiyonun içi boş (dummy) olacak. Kendisine gelen yolları (URL) sadece konsola yazdıracak (Logger) ve başarılı dönerek UI'ı simüle edecektir. 
- Gerçek silme komutlarının yazılması kesin bir dille yasaklanmıştır.

## 2. XPC PROTOKOLÜ VE VERİ TİPİ ZORUNLULUĞU
XPC katmanı (`NSXPCConnection`) Swift struct nesnelerini desteklemez. İletişim protokolünü (@objc protocol) inşa ederken şu kısıtlamalara uyacaksın:
- XPC fonksiyonu parametre olarak `[ScannedFile]` KABUL EDEMEZ.
- Parametre olarak kesinlikle `[String]` dizisi bekleyen bir `@objc protocol CleanerXPCProtocol` oluşturacaksın.
- Zorunlu imza: `@objc func verifyAndPrepareDeletion(paths: [String], withReply reply: @escaping (Bool, Error?) -> Void)`

## 3. MODERN MACOS MİMARİSİ (SMAppService)
- macOS 13+ hedefliyoruz. Eski `SMJobBless` kütüphanelerini, `Info.plist` içindeki `SMPrivilegedExecutables` anahtarlarını veya köhnemiş scriptleri KESİNLİKLE REDDET.
- Yetkilendirme ve daemon kurulumu için `SMAppService.daemon(plistName:)` altyapısını kullanan bir kurulum yöneticisi (`XPCConnectionManager`) inşa et. Helper Bundle ID'si ana uygulama ID'si ile uyumlu (`bunyamin.my-little-mac.helper`) olmalıdır.
- Servis ile ana uygulama arasındaki IPC (Inter-Process Communication) bağlantısını kuracak, bağlantı koptuğunda (invalidation/interruption) temizliği yapacak mekanizmaları kodla.

## 4. GÜVENLİK VE YOL DOĞRULAMASI (PAYLOAD VALIDATION & DRY-RUN)
Gelen `[String]` dizisindeki her bir yol için XPC servisi içinde çok katmanlı bir güvenlik kontrolü yap:
- **Mutlak Yol & Çekirdek Koruması:** Gelen yolun `absolute path` olduğunu doğrula (`/` ile başlamalı). `/System/`, `/usr/bin/`, `/sbin/`, `/usr/sbin/`, `/bin/` gibi kritik macOS çekirdek dizinlerini barındıran yolları anında `Error` ile reddet.
- **Ortak Bağımlılık & Belirsiz Kök Koruması:** `/Group Containers/` gibi ortak kullanım şüphesi taşıyan veya alt öğesi belirtilmemiş çıplak kök sistem dizinlerini (`~/Library/Application Support` vb.) reddet.
- **Sahiplik Doğrulaması (Prefix/Suffix):** Yolların yalnızca hedef uygulamanın kalıntıları olduğunu doğrulayacak String (Prefix/Suffix) kontrol katmanı uygula. Belirsiz veya başka uygulamalara ait yolları reddet.
- **Silinebilirlik Kontrolü (Dry-Run):** Güvenlik filtresini geçen yollar için `FileManager.default.isDeletableFile(atPath:)` metodunu kullanarak silinebilirlik durumunu simüle et ve sonuçları macOS konsoluna (`os_log` ve `print`) yazdır.
- **Tahribat Engeli:** Hiçbir koşulda `rm -rf`, `removeItem(at:)`, `trashItem` kullanma; yalnızca simülasyon sonucunu ana uygulamaya `(Bool, Error?)` ile döndür.
- **UI ve İletişim Bariyeri:** Yalnızca `isSelectedForDeletion == true` olan dosyaların mutlak yolları Helper'a iletilebilir. Kilitli dosyalar IPC hattına sokulamaz.

Görevin bu altyapıyı eksiksiz bir Swift kodu olarak üretmektir.
