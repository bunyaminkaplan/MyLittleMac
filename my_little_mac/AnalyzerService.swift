//
//  AnalyzerService.swift
//  my_little_mac
//
//  Analyzer Agent: Scanner'dan gelen [ScannedFile] dizisindeki her dosyayı
//  macOS sistem mimarisi kurallarına göre analiz ederek riskLevel ve
//  isSelectedForDeletion değerlerini kesinleştirir.
//  Silme kodu İÇERMEZ. Sadece risk değerlendirir.
//

import Foundation

final class AnalyzerService {

    private let fileManager = FileManager.default

    /// Bilinen çapraz-platform / çoklu-uygulama dotfile dizinleri.
    private let sharedDotfilePaths: [String] = [
        "/.android",
        "/.gradle",
        "/.config",
        "/.npm",
        "/.yarn",
        "/.cocoapods",
        "/.gem",
        "/.docker",
        "/.ssh",
        "/.gnupg",
    ]

    /// Root (yönetici) izni gerektiren yüksek riskli dizin önekleri.
    private let rootProtectedPrefixes: [String] = [
        "/usr/local/",
        "/Library/PrivilegedHelperTools/",
    ]

    /// LaunchDaemons / LaunchAgents plist dizinleri.
    private let launchServicePaths: [String] = [
        "/Library/LaunchDaemons",
        "/Library/LaunchAgents",
    ]

    // MARK: - Public API

    /// Ana analiz fonksiyonu. analyzer_agent.md protokolünün tek çıktısıdır.
    /// - Parameters:
    ///   - files: Scanner'dan gelen `[ScannedFile]` dizisi (tümü `.unknown` risk seviyesinde).
    ///   - app: Hedef uygulama bilgisi (`ScannedApp`).
    /// - Returns: Risk seviyeleri kesinleştirilmiş `[ScannedFile]` dizisi.
    func analyze(files: [ScannedFile], for app: ScannedApp) async throws -> [ScannedFile] {

        // Aynı CFBundleIdentifier köküne sahip kardeş uygulamaların varlığını kontrol et
        let siblingBundleExists = await checkForSiblingBundles(app: app)

        var analyzedFiles: [ScannedFile] = []

        for file in files {
            let determinedRisk = try await determineRiskLevel(
                file: file,
                app: app,
                siblingBundleExists: siblingBundleExists
            )

            // Güvenlik Bariyeri: riskLevel'e göre isSelectedForDeletion güncelle
            let isSelected: Bool
            if determinedRisk == .safeToDelete {
                isSelected = true
            } else {
                // sharedDependency, highRisk veya unknown → KESİNLİKLE false
                isSelected = false
            }

            // ScannedFile'ın let property'leri olduğundan yeni instance oluştur
            let analyzedFile = ScannedFile(
                id: file.id,
                url: file.url,
                size: file.size,
                fileType: file.fileType,
                riskLevel: determinedRisk,
                relatedBundleID: file.relatedBundleID,
                isSelectedForDeletion: isSelected
            )

            analyzedFiles.append(analyzedFile)
        }

        return analyzedFiles
    }

    // MARK: - Risk Belirleme (Adımlar 1–4)

    /// Dosya için doğrulama adımlarını ardışık olarak işletir ve nihai risk seviyesini döner.
    private func determineRiskLevel(
        file: ScannedFile,
        app: ScannedApp,
        siblingBundleExists: Bool
    ) async throws -> RiskLevel {

        let path = file.url.path

        // ── Ana Uygulama (.app): Doğrudan silme hedefi ──
        if file.url == app.mainAppUrl || file.fileType == .appBundle {
            return .safeToDelete
        }

        // ── Darwin Cache / Temp (/private/var/folders/): Doğrudan Bundle ID tam eşleşmesi ──
        if (path.contains("/var/folders/") || path.contains("/private/var/folders/")),
           file.url.lastPathComponent == app.bundleIdentifier {
            return .safeToDelete
        }

        // ── Scanner tarafından zaten tam Bundle ID eşleşmesiyle güvenli kabul edilmiş dosyalar ──
        if file.riskLevel == .safeToDelete {
            return .safeToDelete
        }

        // ── Adım 1: LaunchDaemons ve LaunchAgents Doğrulaması ──
        if isPlistInLaunchServiceDirectory(file: file) {
            return try await analyzeLaunchServicePlist(file: file, app: app)
        }

        // ── Adım 3: PKG ve System Root Dosyaları ──
        // (Adım 2'den önce kontrol ediyoruz çünkü root dizin her koşulda highRisk.)
        if isInRootProtectedDirectory(path: path) {
            return .highRisk
        }

        // ── Adım 2: Ortak Bağımlılıklar ve Dotfiles ──
        if isSharedDotfile(path: path) {
            return .highRisk
        }

        if siblingBundleExists && isInSharedApplicationSupport(path: path, bundleID: app.bundleIdentifier) {
            return .sharedDependency
        }

        // ── Adım 4: Standart ve Güvenli Dosyalar ──
        if isStandardOwnedFile(path: path, bundleID: app.bundleIdentifier) {
            return .safeToDelete
        }

        // Hiçbir kurala uymadıysa güvenli tarafta kal
        return .unknown
    }

    // MARK: - Adım 1: LaunchDaemons / LaunchAgents Doğrulaması

    /// Dosyanın bir LaunchService dizinindeki plist olup olmadığını kontrol eder.
    private func isPlistInLaunchServiceDirectory(file: ScannedFile) -> Bool {
        let path = file.url.path
        guard path.hasSuffix(".plist") else { return false }

        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let userLaunchAgents = homeDir + "/Library/LaunchAgents"

        for launchPath in launchServicePaths {
            if path.hasPrefix(launchPath) { return true }
        }

        if path.hasPrefix(userLaunchAgents) { return true }

        return false
    }

    /// Plist dosyasını okuyarak `Program` / `ProgramArguments` alanlarının
    /// hedef .app yolunu içerip içermediğini kontrol eder.
    private func analyzeLaunchServicePlist(file: ScannedFile, app: ScannedApp) async throws -> RiskLevel {
        let plistURL = file.url
        let appPath = app.mainAppUrl.path

        guard fileManager.fileExists(atPath: plistURL.path),
              fileManager.isReadableFile(atPath: plistURL.path) else {
            // Okunamıyorsa güvenli tarafta kal
            return .highRisk
        }

        let plistData: Data
        do {
            plistData = try Data(contentsOf: plistURL)
        } catch {
            return .highRisk
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return .highRisk
        }

        // "Program" anahtarını kontrol et
        if let program = plist["Program"] as? String, program.contains(appPath) {
            return .safeToDelete
        }

        // "ProgramArguments" anahtarını kontrol et
        if let programArgs = plist["ProgramArguments"] as? [String] {
            for arg in programArgs {
                if arg.contains(appPath) {
                    return .safeToDelete
                }
            }
        }

        // Hedef .app yolunu barındırmıyorsa → highRisk
        return .highRisk
    }

    // MARK: - Adım 2: Ortak Bağımlılıklar ve Dotfiles

    /// Dosya yolunun bilinen çapraz-platform dotfile dizinlerinden birinde olup olmadığını kontrol eder.
    private func isSharedDotfile(path: String) -> Bool {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        for dotfilePath in sharedDotfilePaths {
            let fullDotfilePath = homeDir + dotfilePath
            if path.hasPrefix(fullDotfilePath) {
                return true
            }
        }

        return false
    }

    /// Aynı `CFBundleIdentifier` kökünü paylaşan başka bir .app'in sistemde kurulu
    /// olup olmadığını Spotlight ile kontrol eder (Kararlı, Beta, Nightly varyantları).
    private func checkForSiblingBundles(app: ScannedApp) async -> Bool {
        // Bundle ID'nin kök bileşenini al (Örn: "com.company.app" → "com.company")
        let components = app.bundleIdentifier.components(separatedBy: ".")
        guard components.count >= 2 else { return false }
        let rootID = components.dropLast().joined(separator: ".")

        let query = "kMDItemCFBundleIdentifier == '\(rootID).*'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let foundApps = output
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty && $0.hasSuffix(".app") }

        // Kendisi dışında en az bir adet daha .app varsa kardeş uygulama mevcut
        let otherApps = foundApps.filter { $0 != app.mainAppUrl.path }
        return !otherApps.isEmpty
    }

    /// Application Support dizinindeki dosyanın, kardeş uygulamalarla paylaşılıp paylaşılmadığını kontrol eder.
    private func isInSharedApplicationSupport(path: String, bundleID: String) -> Bool {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        let appSupportDirs = [
            homeDir + "/Library/Application Support",
            "/Library/Application Support",
        ]

        // Bundle ID'nin kök bileşeni ile eşleşen Application Support dizini mi?
        let components = bundleID.components(separatedBy: ".")
        guard components.count >= 2 else { return false }
        let rootID = components.dropLast().joined(separator: ".")

        for dir in appSupportDirs {
            if path.hasPrefix(dir) && path.contains(rootID) {
                return true
            }
        }

        return false
    }

    // MARK: - Adım 3: PKG ve System Root Dosyaları

    /// Dosyanın root izni gerektiren korumalı bir dizinde olup olmadığını kontrol eder.
    private func isInRootProtectedDirectory(path: String) -> Bool {
        for prefix in rootProtectedPrefixes {
            if path.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    // MARK: - Adım 4: Standart ve Güvenli Dosyalar

    /// Dosyanın standart Library alt dizinlerinde ve tam bundle ID eşleşmesiyle
    /// tek uygulamaya ait olduğunun kanıtlanıp kanıtlanamayacağını kontrol eder.
    private func isStandardOwnedFile(path: String, bundleID: String) -> Bool {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        let safeDirectories = [
            homeDir + "/Library/Caches/",
            homeDir + "/Library/Preferences/",
            homeDir + "/Library/Containers/",
            homeDir + "/Library/Application Support/",
            homeDir + "/Library/Application Scripts/",
            homeDir + "/Library/WebKit/",
            homeDir + "/Library/HTTPStorages/",
        ]

        for dir in safeDirectories {
            if path.hasPrefix(dir) {
                // Dizin sonrasındaki bileşenin tam olarak bundle ID ile başladığını doğrula
                let remainder = String(path.dropFirst(dir.count))
                let firstComponent = remainder.components(separatedBy: "/").first ?? remainder
                if firstComponent.hasPrefix(bundleID) {
                    return true
                }
            }
        }

        return false
    }
}
