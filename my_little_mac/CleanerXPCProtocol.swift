//
//  CleanerXPCProtocol.swift
//  my_little_mac
//
//  XPC Privileged Helper Architecture: Ana uygulama ile Privileged Helper Tool
//  arasındaki IPC iletişim protokolü. İki süreç sadece bu protokol dosyasını paylaşır.
//  Remote Execution Kanıtı: Helper'dan PID ve UID değerleri döner; ana uygulama
//  UID == 0 (root) kontrolünü zorunlu kılar.
//  Fiziksel dosya silme kodu İÇERMEZ.
//

import Foundation

// MARK: - XPC Protokolü

/// Ana uygulama ile Privileged Helper Tool arasındaki IPC iletişim sözleşmesi.
/// C tabanlı mesajlaşma ve Objective-C köprüsü senkronizasyonu için @objc(CleanerXPCProtocol) ile tanımlanmıştır.
@objc(CleanerXPCProtocol)
protocol CleanerXPCProtocol {

    /// Silinecek dosya yollarını hedef uygulamanın bundleID bilgisiyle ana uygulamadan Helper'a aktarır ve güvenlik kontrolünden geçirir.
    /// Remote Execution Kanıtı: Helper sürecinin PID ve UID değerlerini döner.
    /// - Parameters:
    ///   - bundleID: Hedef uygulamanın CFBundleIdentifier değeri (Örn: "com.google.Chrome").
    ///   - paths: UI tarafından onaylanmış mutlak fiziksel dosya yollarının `[String]` dizisi.
    ///   - reply: İşlem sonucu paketi — `(başarılıMı: Bool, pid: Int, uid: Int, hata: Error?)`.
    @objc func verifyAndPrepareDeletion(
        bundleID: String,
        paths: [String],
        withReply reply: @escaping (Bool, Int, Int, Error?) -> Void
    )

    /// XPC proxy üzerinden Helper sürecinin root (UID: 0) yetkisini ve PID kimliğini doğrular.
    /// - Parameter reply: `(isRoot: Bool, pid: Int, uid: Int)`
    @objc func checkRootAuthority(
        withReply reply: @escaping (Bool, Int, Int) -> Void
    )
}
