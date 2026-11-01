//
//  main.swift
//  CleanerXPCHelper
//
//  XPC Privileged Helper Daemon Ana Giriş Noktası
//  macOS launchd SMAppService tarafından çalıştırılır.
//  DispatchSourceTimer ile boşta kapanma (idle-exit) ve invalidation kapanması desteklenir.
//

import Foundation
import Dispatch
import os.log

private let logger = Logger(subsystem: "bunyamin.my-little-mac.helper", category: "HelperMain")

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logger.info("⚡ Yeni XPC bağlantı talebi alındı.")

        newConnection.exportedInterface = NSXPCInterface(with: CleanerXPCProtocol.self)
        newConnection.exportedObject = CleanerXPCService()

        // 3. İletişim Koptuğunda (Invalidation) Anında Kapanma:
        // invalidationHandler ve interruptionHandler blokları tetiklendiğinde
        // KESİNLİKLE zamanlayıcıyı iptal edip süreci exit(0) ile derhal sonlandır.
        newConnection.invalidationHandler = {
            logger.info("🔌 İstemci XPC bağlantısını sonlandırdı (invalidated). Süreç exit(0) ile derhal kapatılıyor.")
            print("[bunyamin.my-little-mac.helper] [INVALIDATION] Client connection invalidated. Exiting with exit(0)...")
            HelperIdleTimer.shared.cancelAndExitImmediately(reason: "İstemci XPC bağlantısını sonlandırdı (invalidated)")
        }

        newConnection.interruptionHandler = {
            logger.warning("⚠️ İstemci XPC bağlantısı kesintiye uğradı (interrupted). Süreç exit(0) ile derhal kapatılıyor.")
            print("[bunyamin.my-little-mac.helper] [INTERRUPTION] Client connection interrupted. Exiting with exit(0)...")
            HelperIdleTimer.shared.cancelAndExitImmediately(reason: "İstemci XPC bağlantısı kesintiye uğradı (interrupted)")
        }

        newConnection.resume()

        // 1. Bağlantı kurulduktan sonra belirli bir süre (10 saniye) yeni bir istek gelmezse süreci exit(0) ile sonlandıran zamanlayıcıyı başlat.
        HelperIdleTimer.shared.startTimer()

        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: "bunyamin.my-little-mac.helper")
listener.delegate = delegate
listener.resume()
logger.info("🚀 bunyamin.my-little-mac.helper XPC Listener başlatıldı (Idle Timer ve Invalidation Exit devrede).")

// Başlangıçta henüz bağlantı kurulmadıysa 10 saniye sonra süreci sonlandıran güvenlik zamanlayıcısı
HelperIdleTimer.shared.startTimer()

dispatchMain()
