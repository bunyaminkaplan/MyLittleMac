//
//  main.swift
//  CleanerXPCHelper
//
//  XPC Privileged Helper Daemon Ana Giriş Noktası
//  macOS launchd SMAppService tarafından çalıştırılır.
//

import Foundation

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: CleanerXPCProtocol.self)
        newConnection.exportedObject = CleanerXPCService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: "bunyamin.my-little-mac.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
