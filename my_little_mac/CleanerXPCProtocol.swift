//
//  CleanerXPCProtocol.swift
//  my_little_mac
//
//  XPC Privileged Helper Architecture: Ana uygulama ile Privileged Helper Tool
//  arasındaki IPC iletişim protokolü. Veri aktarımı [String] mutlak fiziksel dosya
//  yolları üzerinden yapılır; Swift struct nesneleri ([ScannedFile]) desteklenmez.
//  Fiziksel dosya silme kodu İÇERMEZ.
//

import Foundation

// MARK: - XPC Protokolü

/// Ana uygulama ile Privileged Helper Tool arasındaki IPC iletişim sözleşmesi.
/// C tabanlı mesajlaşma ve Objective-C köprüsü senkronizasyonu için @objc(CleanerXPCProtocol) ile tanımlanmıştır.
@objc(CleanerXPCProtocol)
protocol CleanerXPCProtocol {

    /// Silinecek dosya yollarını hedef uygulamanın bundleID bilgisiyle ana uygulamadan Helper'a aktarır ve güvenlik kontrolünden geçirir.
    /// - Parameters:
    ///   - bundleID: Hedef uygulamanın CFBundleIdentifier değeri (Örn: "com.google.Chrome").
    ///   - paths: UI tarafından filtrelenerek gelen (yalnızca isSelectedForDeletion == true)
    ///            mutlak dosya yollarının `[String]` (NSArray<NSString *>) dizisi.
    ///   - reply: İşlem sonucu — `(başarılıMı, hata)`.
    @objc func verifyAndPrepareDeletion(bundleID: String, paths: [String], withReply reply: @escaping (Bool, Error?) -> Void)
}
