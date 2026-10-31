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
        "/.m2",
        "/.npm",
        "/.yarn",
        "/.cocoapods",
        "/.gem",
        "/.cargo",
        "/.rustup",
        "/.docker",
        "/.config",
        "/.local",
        "/.nvm",
        "/.sdkman",
        "/.pyenv",
        "/.rbenv",
        "/.ssh",
        "/.gnupg",
        "/.composer",
        "/.nuget",
        "/.pnpm",
        "/.pub-cache"
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

    /// Bilinen yazılım ailesi tanımları (Adobe, JetBrains, Microsoft, Google, Apple vb.).
    private struct KnownSoftwareFamily {
        let name: String
        let bundleKeywords: [String]
        let rootFolders: [String]
        let sharedSubfolders: [String]
    }

    private let knownFamilies: [KnownSoftwareFamily] = [
        KnownSoftwareFamily(
            name: "Adobe",
            bundleKeywords: ["adobe"],
            rootFolders: ["Adobe"],
            sharedSubfolders: ["Common", "CoreSync", "OOBE", "Caps", "AAMUpdater", "CEP", "Creative Cloud Libraries", "Adobe Desktop Common", "Adobe Application Support", "CameraRaw"]
        ),
        KnownSoftwareFamily(
            name: "JetBrains",
            bundleKeywords: ["jetbrains"],
            rootFolders: ["JetBrains"],
            sharedSubfolders: ["consentOptions", "marketplace", "Toolbox"]
        ),
        KnownSoftwareFamily(
            name: "Microsoft",
            bundleKeywords: ["microsoft"],
            rootFolders: ["Microsoft"],
            sharedSubfolders: ["MAU2.0", "AutoUpdate", "Office", "EdgeShared", "PlayReady", "Silverlight"]
        ),
        KnownSoftwareFamily(
            name: "Google",
            bundleKeywords: ["google"],
            rootFolders: ["Google"],
            sharedSubfolders: ["GoogleSoftwareUpdate", "Chrome Component Updates", "Google Software Update"]
        ),
        KnownSoftwareFamily(
            name: "Apple",
            bundleKeywords: ["apple"],
            rootFolders: ["Apple"],
            sharedSubfolders: ["Developer Tools", "MobileDevice", "CoreTelephony", "Apple Desktop"]
        ),
        KnownSoftwareFamily(
            name: "Valve",
            bundleKeywords: ["valvesoftware", "steam"],
            rootFolders: ["Steam"],
            sharedSubfolders: ["steamapps", "config"]
        ),
        KnownSoftwareFamily(
            name: "Epic Games",
            bundleKeywords: ["epicgames"],
            rootFolders: ["Epic"],
            sharedSubfolders: ["EpicGamesLauncher", "UnrealEngine"]
        ),
        KnownSoftwareFamily(
            name: "Mozilla",
            bundleKeywords: ["mozilla"],
            rootFolders: ["Mozilla"],
            sharedSubfolders: ["Extensions", "SystemExtensions"]
        )
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
            // UI Güvenlik Bariyeri: Gelişmiş aramadan dönen dosyaların discoveryMethod değeri .standard, .spotlight, .pkgutil veya .heuristic DEĞİLSE,
            // arayüzdeki seçim kutuları (Checkbox) KESİNLİKLE varsayılan olarak kapalı (isSelectedForDeletion = false) başlatılacaktır.
            // İSTİSNA: .heuristicOverride katmanı .safeToDelete olarak gelir ve silinmeye hazır (seçili) başlatılır.
            if file.discoveryMethod != .standard && file.discoveryMethod != .spotlight && file.discoveryMethod != .pkgutil && file.discoveryMethod != .heuristic {
                let isSelected: Bool
                if file.discoveryMethod == .heuristicOverride && file.riskLevel == .safeToDelete {
                    isSelected = true
                } else {
                    isSelected = false
                }

                let analyzedFile = ScannedFile(
                    id: file.id,
                    url: file.url,
                    size: file.size,
                    fileType: file.fileType,
                    riskLevel: file.riskLevel,
                    relatedBundleID: file.relatedBundleID,
                    discoveryMethod: file.discoveryMethod,
                    reasoningText: file.reasoningText,
                    isSelectedForDeletion: isSelected
                )
                analyzedFiles.append(analyzedFile)
                continue
            }

            let (determinedRisk, reasoning) = try await determineRiskLevelWithReasoning(
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
                discoveryMethod: file.discoveryMethod,
                reasoningText: file.reasoningText ?? reasoning,
                isSelectedForDeletion: isSelected
            )

            analyzedFiles.append(analyzedFile)
        }

        // Parent-Child çakışma çözümünü ve override izolasyonunu analiz edilen listede de garantiye al
        let resolvedFiles = resolveParentChildCollisions(in: analyzedFiles, appUrl: app.mainAppUrl)

        // UI Güvenlik Bariyeri: riskLevel değeri .safeToDelete olmayan HİÇBİR klasör varsayılan olarak seçili (true) başlatılamaz.
        return resolvedFiles.map { file in
            if file.riskLevel != .safeToDelete && file.isSelectedForDeletion {
                return ScannedFile(
                    id: file.id,
                    url: file.url,
                    size: file.size,
                    fileType: file.fileType,
                    riskLevel: file.riskLevel,
                    relatedBundleID: file.relatedBundleID,
                    discoveryMethod: file.discoveryMethod,
                    reasoningText: file.reasoningText,
                    isSelectedForDeletion: false
                )
            }
            return file
        }
    }

    // MARK: - Parent-Child Klasör Çakışması & Override İzolasyonu (Collision Resolution)

    /// Eğer listede bir "Üst Klasör" VE aynı zamanda bu klasörün içindeki bir "Alt Klasör/Dosya" birlikte bulunuyorsa:
    /// Üst klasörün riskLevel değerini KESİNLİKLE .highRisk (Kod: 2) olarak zorlar ve isSelectedForDeletion = false yapar.
    private func resolveParentChildCollisions(in files: [ScannedFile], appUrl: URL) -> [ScannedFile] {
        let standardizedPaths = files.map { $0.url.standardizedFileURL.path }
        let standardizedAppPath = appUrl.standardizedFileURL.path

        // .heuristicOverride ile gelen alt dosyaların standart yolları
        let overrideChildPaths = files
            .filter { $0.discoveryMethod == .heuristicOverride }
            .map { $0.url.standardizedFileURL.path }

        return files.map { file in
            let parentPath = file.url.standardizedFileURL.path

            if parentPath == standardizedAppPath || file.fileType == .appBundle {
                return file
            }

            let parentPathWithSlash = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"

            // 1. Override İzolasyonu: overrides.json üzerinden .heuristicOverride ile bulunmuş
            // spesifik alt dosyalar varsa, bu alt dosyaların ÜST KLASÖRÜNÜ KESİNLİKLE .highRisk yap
            // ve isSelectedForDeletion = false olarak kilitle.
            let hasOverrideChild = overrideChildPaths.contains { childPath in
                childPath != parentPath && childPath.hasPrefix(parentPathWithSlash)
            }

            if hasOverrideChild {
                return ScannedFile(
                    id: file.id,
                    url: file.url,
                    size: file.size,
                    fileType: file.fileType,
                    riskLevel: .highRisk,
                    relatedBundleID: file.relatedBundleID,
                    discoveryMethod: file.discoveryMethod,
                    reasoningText: "Güvenli alt klasörler (.heuristicOverride) bağımsız hedeflendiğinden üst klasör kullanıcı verilerini korumak amacıyla yüksek riskli (.highRisk) olarak kilitlendi",
                    isSelectedForDeletion: false
                )
            }

            // 2. Genel parent-child çakışması:
            let hasChildInList = standardizedPaths.contains { childPath in
                childPath != parentPath && childPath.hasPrefix(parentPathWithSlash)
            }

            if hasChildInList {
                return ScannedFile(
                    id: file.id,
                    url: file.url,
                    size: file.size,
                    fileType: file.fileType,
                    riskLevel: .highRisk,
                    relatedBundleID: file.relatedBundleID,
                    discoveryMethod: file.discoveryMethod,
                    reasoningText: "Alt klasör/dosyaları bağımsız olarak listelendiğinden üst klasör yüksek riskli (.highRisk) olarak kilitlendi",
                    isSelectedForDeletion: false
                )
            }

            return file
        }
    }

    // MARK: - Risk Belirleme (Adımlar 1–4)

    /// Dosya için doğrulama adımlarını ardışık olarak işletir ve nihai risk seviyesi ile gerekçesini döner.
    private func determineRiskLevelWithReasoning(
        file: ScannedFile,
        app: ScannedApp,
        siblingBundleExists: Bool
    ) async throws -> (RiskLevel, String) {

        let path = file.url.path

        // ── Ana Uygulama (.app): Doğrudan silme hedefi ──
        if file.url == app.mainAppUrl || file.fileType == .appBundle {
            return (.safeToDelete, "Hedef uygulama ana paketi (.app)")
        }

        // ── Darwin Cache / Temp (/private/var/folders/): Doğrudan Bundle ID tam eşleşmesi ──
        if (path.contains("/var/folders/") || path.contains("/private/var/folders/")),
           file.url.lastPathComponent == app.bundleIdentifier {
            return (.safeToDelete, "Darwin dinamik önbellek (tam bundle ID eşleşmesi)")
        }

        // ── Darwin Cache / Temp (/private/var/folders/): Suffix / alt süreç dosyaları (hasPrefix) ──
        if (path.contains("/var/folders/") || path.contains("/private/var/folders/")),
           file.url.lastPathComponent.hasPrefix(app.bundleIdentifier) {
            return (.unknown, file.reasoningText ?? "Darwin dinamik alt/yan süreç klasörü (suffix eşleşmesi: \(file.url.lastPathComponent))")
        }

        // ── Scanner tarafından .highRisk olarak zorlanmış dosyalar (Parent-Child çakışması vb.) ──
        if file.riskLevel == .highRisk {
            return (.highRisk, file.reasoningText ?? "Kök dizin / korumalı veya alt öğeleri bulunan üst klasör")
        }

        // ── Scanner tarafından zaten tam Bundle ID eşleşmesiyle güvenli kabul edilmiş dosyalar ──
        if file.riskLevel == .safeToDelete {
            return (.safeToDelete, file.reasoningText ?? "Bundle ID eşleşmesiyle güvenli kütüphane dosyası")
        }

        // ── Adım 1: LaunchDaemons ve LaunchAgents Doğrulaması ──
        if isPlistInLaunchServiceDirectory(file: file) {
            let risk = try await analyzeLaunchServicePlist(file: file, app: app)
            let reason = (risk == .safeToDelete)
                ? "LaunchService plist hedef uygulamayı doğruladı"
                : "LaunchService plist hedef uygulamayı doğrulamadı"
            return (risk, reason)
        }

        // ── Adım 3: PKG ve System Root Dosyaları ──
        // (Adım 2'den önce kontrol ediyoruz çünkü root dizin her koşulda highRisk.)
        if isInRootProtectedDirectory(path: path) {
            return (.highRisk, "Kök dizin / yönetici izni gerektiren korumalı sistem yolu")
        }

        // ── Adım 2: Ortak Bağımlılıklar, Yazılım Ailesi ve Dotfiles ──
        if isSharedDotfile(path: path) {
            return (.sharedDependency, "Ortak paylaşılan araç, paket yöneticisi dotfile veya SDK dizini")
        }

        let familyCheck = checkSharedSoftwareFamily(path: path, app: app, siblingBundleExists: siblingBundleExists)
        if familyCheck.isShared {
            return (.highRisk, familyCheck.reason)
        }

        if siblingBundleExists && isInSharedApplicationSupport(path: path, bundleID: app.bundleIdentifier) {
            return (.highRisk, "Kardeş uygulamalarla paylaşılan Application Support dizini (yazılım ailesi koruması)")
        }

        // ── Adım 4: Standart ve Güvenli Dosyalar (Tam Bundle ID Eşleşmesi) ──
        if isStandardOwnedFile(path: path, bundleID: app.bundleIdentifier) {
            return (.safeToDelete, "Standart kütüphane dizini, CFBundleIdentifier eşleşmesi tam")
        }

        // ── Adım 5: Uygulama Bileşeni ve Sürüm Dizinleri Doğrulaması (Application Support, Caches vb.) ──
        let componentCheck = checkApplicationOwnedComponent(path: path, app: app)
        if componentCheck.isOwned {
            return (.safeToDelete, componentCheck.reason)
        }

        // Hiçbir kurala uymadıysa güvenli tarafta kal
        return (.unknown, "Sahiplik ve risk kesinleştirilemedi")
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

    // MARK: - Adım 2: Ortak Bağımlılıklar, Dotfiles ve Paylaşılan SDK'lar

    /// Dosya yolunun bilinen paylaşılan araç, paket yöneticisi dotfile (.gradle, .m2, .npm vb.) veya SDK dizinlerinden birinde olup olmadığını kontrol eder.
    private func isSharedDotfile(path: String) -> Bool {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let standardizedPath = (path as NSString).standardizingPath

        // 1. Home dizini altındaki bilinen dotfile ve paket yöneticisi yolları
        for dotfilePath in sharedDotfilePaths {
            let fullDotfilePath = (homeDir as NSString).appendingPathComponent(String(dotfilePath.dropFirst()))
            if standardizedPath == fullDotfilePath || standardizedPath.hasPrefix(fullDotfilePath + "/") {
                return true
            }
        }

        // 2. Paylaşılan SDK ve geliştirici ortamı dizinleri
        let lowerPath = standardizedPath.lowercased()
        let sharedSDKSubstrings = [
            "/android/sdk",
            "/library/android",
            "/java/javavirtualmachines",
            "/developer/commandlinetools",
            "/developer/coresimulator",
            "/developer/shared"
        ]

        for sdkSub in sharedSDKSubstrings {
            if lowerPath.contains(sdkSub) {
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

    /// Hedef uygulamanın ait olduğu yazılım ailesi (Adobe, JetBrains, Microsoft, Google vb.),
    /// üretici (Vendor) ortak kök dizinleri veya kararlı/beta sürüm varyantlarına ait paylaşılan
    /// yapılandırma klasörlerini tespit eder.
    /// Bu tip ortak dizinler KESİNLİKLE riskLevel: .highRisk olarak işaretlenir.
    private func checkSharedSoftwareFamily(
        path: String,
        app: ScannedApp,
        siblingBundleExists: Bool
    ) -> (isShared: Bool, reason: String) {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let lowerBundleID = app.bundleIdentifier.lowercased()
        let appName = app.name.lowercased()
        let appNameWithoutSpaces = appName.replacingOccurrences(of: " ", with: "")

        let baseSearchPrefixes = [
            homeDir + "/Library/Application Support/",
            "/Library/Application Support/",
            homeDir + "/Library/Preferences/",
            "/Library/Preferences/",
            homeDir + "/Library/Caches/",
            "/Library/Caches/",
            homeDir + "/Library/Containers/",
            homeDir + "/Library/Group Containers/"
        ]

        // 1. Bilinen Yazılım Aileleri (Adobe, JetBrains, Microsoft, Google vb.) Kontrolü
        for family in knownFamilies {
            let isAppInFamily = family.bundleKeywords.contains { kw in
                lowerBundleID.contains(kw) || appName.contains(kw)
            }
            guard isAppInFamily else { continue }

            for prefix in baseSearchPrefixes {
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                let components = relative.components(separatedBy: "/").filter { !$0.isEmpty }
                guard !components.isEmpty else { continue }

                let topFolder = components[0]
                let isTopFolderFamilyRoot = family.rootFolders.contains { $0.lowercased() == topFolder.lowercased() }
                guard isTopFolderFamilyRoot else { continue }

                // Durum A: Doğrudan yazılım ailesi ortak kök dizini (Örn: ~/Library/Application Support/Adobe)
                if components.count == 1 {
                    return (true, "\(family.name) yazılım ailesi ortak kök dizini (Suite root: \(topFolder))")
                }

                // Durum B: Bilinen paylaşılan alt servis/araç klasörü (Örn: Adobe/Common, Microsoft/MAU2.0)
                let subFolder = components[1]
                let isKnownSharedSub = family.sharedSubfolders.contains { $0.lowercased() == subFolder.lowercased() }
                if isKnownSharedSub {
                    return (true, "\(family.name) yazılım ailesi paylaşılan bileşen dizini (\(topFolder)/\(subFolder))")
                }

                // Durum C: Sibling bundle varsa veya alt klasör spesifik olarak bu uygulamanın adını içermiyorsa
                let subLower = subFolder.lowercased()
                let containsAppName = (!appNameWithoutSpaces.isEmpty && subLower.contains(appNameWithoutSpaces)) ||
                                      (!appName.isEmpty && subLower.contains(appName)) ||
                                      subLower.contains(lowerBundleID)

                if siblingBundleExists && !containsAppName {
                    return (true, "\(family.name) yazılım ailesi kardeş uygulamalarla paylaşılan yapılandırma klasörü (\(topFolder)/\(subFolder))")
                }
            }
        }

        // 2. Dinamik Üretici (Vendor) Kök Dizini ve Kardeş Uygulama (Sibling) Koruması
        let segments = lowerBundleID.components(separatedBy: ".")
        let vendor = (segments.count >= 2 && !["com", "org", "net", "io", "app", "co", "uk", "de"].contains(segments[0]))
            ? segments[0]
            : (segments.count >= 2 ? segments[1] : "")

        if !vendor.isEmpty && vendor != "apple" && vendor.count >= 3 {
            for prefix in baseSearchPrefixes {
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                let components = relative.components(separatedBy: "/").filter { !$0.isEmpty }
                guard !components.isEmpty else { continue }

                let topFolder = components[0]
                let topLower = topFolder.lowercased().replacingOccurrences(of: " ", with: "")

                // Eğer üst klasör doğrudan vendor adıysa (Örn: /Library/Application Support/Company)
                if topLower == vendor.lowercased() {
                    if components.count == 1 {
                        return (true, "Yazılım ailesi/üretici ortak kök dizini (\(topFolder))")
                    }

                    if siblingBundleExists {
                        let subFolder = components[1]
                        let subLower = subFolder.lowercased().replacingOccurrences(of: " ", with: "")
                        let containsApp = (!appNameWithoutSpaces.isEmpty && subLower.contains(appNameWithoutSpaces)) ||
                                          subLower.contains(lowerBundleID)
                        if !containsApp {
                            return (true, "Kardeş uygulamalarla paylaşılan üretici yapılandırma klasörü (\(topFolder)/\(subFolder))")
                        }
                    }
                }
            }
        }

        // 3. Sürüm / Varyant Koruması (Stable / Beta / Canary / Dev / Preview)
        let editionKeywords = ["beta", "canary", "dev", "preview", "insider", "nightly"]
        let appIsEdition = editionKeywords.contains { lowerBundleID.contains($0) || appName.contains($0) }

        if siblingBundleExists && appIsEdition {
            // Eğer taranan uygulama bir Beta/Dev varyantıysa, kararlı sürüme (stable) ait klasörleri silmeyi engelle
            for prefix in baseSearchPrefixes {
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                let relativeLower = relative.lowercased()
                let pathHasEditionKeyword = editionKeywords.contains { relativeLower.contains($0) }
                if !pathHasEditionKeyword {
                    return (true, "Kararlı (Stable) ana sürüm ile paylaşılan veya ona ait yapılandırma klasörü")
                }
            }
        }

        return (false, "")
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

    // MARK: - Adım 5: Uygulama Bileşeni ve Sürüm Dizinleri Doğrulaması

    /// Application Support, Caches, Preferences vb. altındaki yolların doğrudan hedef uygulamaya ait
    /// bir sürüm dizini (Örn: Google/AndroidStudio2025.2.2 veya JetBrains/IntelliJIdea2024.1) olup olmadığını doğrular.
    /// Paket veya klasör adında sürüm numarası içeriyorsa ve doğrudan uygulamanın bir bileşeniyse safeToDelete döner.
    private func checkApplicationOwnedComponent(
        path: String,
        app: ScannedApp
    ) -> (isOwned: Bool, reason: String) {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        let targetPrefixes = [
            homeDir + "/Library/Application Support/",
            "/Library/Application Support/",
            homeDir + "/Library/Caches/",
            "/Library/Caches/",
            homeDir + "/Library/Preferences/",
            "/Library/Preferences/",
            homeDir + "/Library/Logs/",
            "/Library/Logs/",
            homeDir + "/Library/Saved Application State/",
            homeDir + "/Library/WebKit/",
            homeDir + "/Library/HTTPStorages/"
        ]

        let lowerBundleID = app.bundleIdentifier.lowercased()
        let appName = app.name.lowercased()
        let appNameWithoutSpaces = appName.replacingOccurrences(of: " ", with: "")

        let bundleSegments = lowerBundleID.components(separatedBy: ".").filter { !$0.isEmpty }
        let vendor = (bundleSegments.count >= 2 && !["com", "org", "net", "io", "app", "co", "uk", "de"].contains(bundleSegments[0]))
            ? bundleSegments[0]
            : (bundleSegments.count >= 2 ? bundleSegments[1] : "")

        // Anlamlı uygulama belirteçleri (Örn: com.google.android.studio -> ["android", "studio"])
        let appTokens: [String] = {
            if bundleSegments.count >= 3 {
                return Array(bundleSegments.dropFirst(2))
            } else if bundleSegments.count == 2 {
                return [bundleSegments[1]]
            }
            return [lowerBundleID]
        }()
        let combinedBundleAppToken = appTokens.joined()

        for prefix in targetPrefixes {
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let components = relative.components(separatedBy: "/").filter { !$0.isEmpty }
            guard !components.isEmpty else { continue }

            // Durum 1: Vendor/AppNameVersion (Örn: Google/AndroidStudio2025.2.2 veya JetBrains/IntelliJIdea2024.1)
            if components.count >= 2 {
                let vendorFolder = components[0].lowercased().replacingOccurrences(of: " ", with: "")
                let candidateFolder = components[1]
                let lowerCandidate = candidateFolder.lowercased()
                let candidateWithoutSpaces = lowerCandidate.replacingOccurrences(of: " ", with: "")

                // Vendor eşleşmesi (Google, JetBrains, Adobe vb.)
                let matchesVendor = (!vendor.isEmpty && (vendorFolder == vendor || vendorFolder.contains(vendor) || vendor.contains(vendorFolder))) ||
                                    lowerBundleID.contains(vendorFolder)

                if matchesVendor {
                    // Aday klasörün uygulamanın adı veya Bundle ID belirteçleriyle eşleşmesi
                    let matchesAppToken = (!appNameWithoutSpaces.isEmpty && candidateWithoutSpaces.hasPrefix(appNameWithoutSpaces)) ||
                                          (!appName.isEmpty && lowerCandidate.hasPrefix(appName)) ||
                                          candidateWithoutSpaces.hasPrefix(combinedBundleAppToken) ||
                                          (appTokens.count >= 2 && appTokens.allSatisfy { lowerCandidate.contains($0) })

                    if matchesAppToken {
                        // Sürüm numarası veya alt sürüm kalıbı kontrolü (Örn: 2025.2.2, 2024.1, 4.0, v2 vb.)
                        let hasVersionPattern = candidateFolder.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) != nil
                        let reason = hasVersionPattern
                            ? "Uygulama sürüm bileşeni dizini doğrulandı (\(components[0])/\(candidateFolder))"
                            : "Uygulama alt bileşen dizini doğrulandı (\(components[0])/\(candidateFolder))"
                        return (true, reason)
                    }
                }
            }

            // Durum 2: Doğrudan Application Support altında AppNameVersion (Örn: AndroidStudio2025.2.2 veya Sublime Text 3)
            if components.count >= 1 {
                let candidateFolder = components[0]
                let lowerCandidate = candidateFolder.lowercased()
                let candidateWithoutSpaces = lowerCandidate.replacingOccurrences(of: " ", with: "")

                let matchesAppToken = (!appNameWithoutSpaces.isEmpty && candidateWithoutSpaces.hasPrefix(appNameWithoutSpaces)) ||
                                      (!appName.isEmpty && lowerCandidate.hasPrefix(appName)) ||
                                      candidateWithoutSpaces.hasPrefix(combinedBundleAppToken) ||
                                      (appTokens.count >= 2 && appTokens.allSatisfy { lowerCandidate.contains($0) })

                if matchesAppToken {
                    let hasVersionPattern = candidateFolder.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) != nil
                    let reason = hasVersionPattern
                        ? "Uygulama sürüm bileşeni dizini doğrulandı (\(candidateFolder))"
                        : "Uygulama bileşen dizini doğrulandı (\(candidateFolder))"
                    return (true, reason)
                }
            }
        }

        return (false, "")
    }
}
