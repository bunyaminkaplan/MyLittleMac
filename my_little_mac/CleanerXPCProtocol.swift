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
@objc protocol CleanerXPCProtocol {

    /// Silinecek dosya yollarını ana uygulamadan Helper'a aktarır ve güvenlik kontrolünden geçirir.
    /// - Parameters:
    ///   - paths: UI tarafından filtrelenerek gelen (yalnızca isSelectedForDeletion == true)
    ///            mutlak dosya yollarının `[String]` dizisi.
    ///   - reply: İşlem sonucu — `(başarılıMı, hata)`.
    func verifyAndPrepareDeletion(paths: [String], withReply reply: @escaping (Bool, Error?) -> Void)
}
