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
- Parametre olarak kesinlikle `[URL]` (veya `[String]`) dizisi bekleyen bir `@objc protocol CleanerXPCProtocol` oluşturacaksın.
- Örnek imza: `@objc func removeFiles(at urls: [URL], withReply reply: @escaping (Bool, Error?) -> Void)`

## 3. MODERN MACOS MİMARİSİ (SMAppService)
- macOS 14+ hedefliyoruz. Eski `SMJobBless` kütüphanelerini, `Info.plist` içindeki `SMPrivilegedExecutables` anahtarlarını veya köhnemiş scriptleri kullanma.
- Yetkilendirme ve daemon kurulumu için `SMAppService.daemon(plistName:)` altyapısını kullanan bir kurulum yöneticisi (Installer) sınıfı inşa et.
- Servis ile ana uygulama arasındaki IPC (Inter-Process Communication) bağlantısını kuracak, bağlantı koptuğunda (invalidation/interruption) temizliği yapacak mekanizmaları kodla.

## 4. GÜVENLİK VE YOL DOĞRULAMASI (PATH TRAVERSAL KORUMASI)
Gelen `[URL]` dizisindeki her bir yol için XPC servisi içinde ikincil bir güvenlik kontrolü (dummy log içinde) yap:
- Gelen URL'nin `/System/` dizinine veya kullanıcı dışı kritik macOS boot dosyalarına işaret edip etmediğini kontrol eden bir güvenlik duvarı fonksiyonu yaz. İşaret ediyorsa XPC servisi `Error` dönerek işlemi reddetmelidir.
- Sadece `/Library/`, `~/Library/`, `/Applications/` veya `/usr/local/` yollarına izin veren bir doğrulama katmanı (whitelist) ekle.

Görevin bu altyapıyı eksiksiz bir Swift kodu olarak üretmektir.
