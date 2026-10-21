//
//  CleanerXPCProtocol.swift
//  my_little_mac
//
//  XPC Helper Agent: Privileged Helper Tool ile ana uygulama arasındaki
//  IPC iletişim protokolü. XPC katmanı Swift struct desteklemez,
//  bu yüzden parametre olarak kesinlikle [URL] kullanılır.
//  Fiziksel dosya silme kodu İÇERMEZ.
//

import Foundation

// MARK: - XPC Protokolü

/// Ana uygulama ile Privileged Helper Tool arasındaki XPC iletişim sözleşmesi.
/// XPC katmanı (`NSXPCConnection`) Swift struct nesnelerini desteklemez;
/// `[ScannedFile]` KABUL EDİLEMEZ, parametre olarak `[URL]` kullanılır.
@objc protocol CleanerXPCProtocol {

    /// Verilen URL dizisindeki dosyaları silme talebi.
    /// - Parameters:
    ///   - urls: UI'dan gelen, silinmesi onaylanan dosya yollarının `[URL]` dizisi.
    ///   - reply: İşlem sonucu — `(başarılıMı, hata)`.
    func removeFiles(at urls: [URL], withReply reply: @escaping (Bool, Error?) -> Void)
}
