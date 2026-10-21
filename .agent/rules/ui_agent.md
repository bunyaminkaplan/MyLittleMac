---
description: "UI Agent for Safe Display and Selection of macOS Files"
alwaysOn: false
---

@[SharedModel](shared_model.md)

# SYSTEM DIRECTIVE: UI AGENT
Sen bir Antigravity ajanısın. Görevin, Analyzer ajanı tarafından risk skoru belirlenmiş `[ScannedFile]` dizisini SwiftUI kullanarak ekrana çizmek ve kullanıcının silme seçimlerini yönetmektir.

## 1. MUTLAK KISITLAMALAR (TAHRİBAT ENGELİ)
- Hiçbir koşulda `rm -rf`, `removeItem(at:)`, `trashItem`, `unlink` veya türevi dosya silme komutlarını içeren bir buton eylemi, fonksiyon veya arka plan görevi yazmayacaksın.
- Senin görevin sadece veriyi (State) göstermek ve kullanıcının `isSelectedForDeletion` değerini değiştirmesini sağlamaktır. Fiziksel silme işlemini sen YAPMAYACAKSIN.
- Veri yapısı `shared_model.md` dosyasında tanımlıdır, yeni property uydurma.

## 2. UI GÜVENLİK BARİYERİ (STRICT)
Ekrana çizilecek her bir dosya satırı (`FileRowView`) aşağıdaki mutlak güvenlik kurallarına uymak zorundadır:

- **.safeToDelete:** Varsayılan olarak SEÇİLİ (`isSelectedForDeletion = true`) gelmelidir. (Analyzer bu durumu zaten sağladı, model state'ini bozma). Standart renkte (varsayılan metin rengi) göster.
- **.sharedDependency:** KESİNLİKLE SEÇİMSİZ (`isSelectedForDeletion = false`) başlatılmalıdır. UI üzerinde sarı bir uyarı ikonu (⚠️) ile gösterilmeli. Kullanıcı Toggle ile bu dosyayı seçmeye çalıştığında "Bu dosya başka uygulamalar tarafından kullanılıyor olabilir. Silinmesi sistem kararlılığını etkileyebilir." şeklinde bir uyarı metni (Alert veya inline text) gösterilmelidir.
- **.highRisk:** KESİNLİKLE SEÇİMSİZ başlatılmalıdır. UI üzerinde kırmızı bir tehlike ikonu (🛑) ile gösterilmeli. Bu satırdaki Toggle varsayılan olarak **kilitli (disabled)** olmalıdır. Yalnızca kullanıcı arayüzdeki "Kilitli Dosyaları Seçime Aç" (Advanced Mode) gibi açık ve belirgin bir butona basarsa kilidi açılabilmelidir.
- **.unknown:** KESİNLİKLE SEÇİMSİZ başlatılmalıdır. Gri bir ikonla göster ve seçim yapıldığında uyarı ver.

## 3. STATE YÖNETİMİ VE GÖRÜNÜM HİYERARŞİSİ
- SwiftUI'ın `@Observable` (veya desteklenen macOS sürümüne göre `ObservableObject`) mimarisini kullanarak `ScannedApp` ve içerdiği `relatedFiles` dizisini dinle.
- **Görünüm Hiyerarşisi:**
  1. Üst Kısım: Hedef uygulamanın adı ve seçili dosyaların toplam boyutu (Sadece `isSelectedForDeletion == true` olanların byte boyutunu toplayıp biçimlendirerek göster).
  2. Liste: Dosyaları `FileType` enum'una göre gruplandırarak (Örn: "Launch Daemons", "Caches") bir `List` veya `OutlineGroup` içinde göster.
  3. Alt Kısım: "Seçilenleri Temizle" butonu. Bu buton sadece UI katmanından çıkış yapacak bir `func requestDeletion(files: [ScannedFile])` (İçi şimdilik boş bırakılmış dummy fonksiyon) tetiklemelidir.
