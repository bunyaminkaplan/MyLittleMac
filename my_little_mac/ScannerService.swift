//
//  ScannerService.swift
//  my_little_mac
//
//  Scanner Agent: Verilen bir .app paketinin macOS sistemindeki tüm artık
//  dosyalarını CFBundleIdentifier temelli olarak tespit eder.
//  Silme veya doğrulama kodu İÇERMEZ. Sadece bulur ve listeler.
//

import Foundation

final class ScannerService {

    private let fileManager = FileManager.default

    // MARK: - Public API

    /// Ana tarama fonksiyonu. scanner_agent.md protokolünün tek çıktısıdır.
    /// - Parameters:
    ///   - appUrl: Seçilen `.app` paketinin URL'i.
    ///   - isAdvancedModeEnabled: Gelişmiş tarama protokollerinin (Team ID, BTM, System Extensions, Heuristics) tetiklenip tetiklenmeyeceği.
    /// - Returns: Bulunan tüm ilişkili dosyaların `[ScannedFile]` listesi.
    func scan(appUrl: URL, isAdvancedModeEnabled: Bool = false) async throws -> [ScannedFile] {

        // Adım 1: CFBundleIdentifier Çıkarımı
        let bundleID = try extractBundleIdentifier(from: appUrl)

        // 1. Kayıp Ana Uygulama: Taramaya başladığı an appUrl'yi ScannedFile olarak yarat
        let mainAppScannedFile = ScannedFile(
            id: UUID(),
            url: appUrl,
            size: fileSize(at: appUrl),
            fileType: .appBundle,
            riskLevel: .unknown,
            relatedBundleID: bundleID,
            discoveryMethod: .standard,
            reasoningText: "Hedef uygulama ana paketi (.app)",
            isSelectedForDeletion: false
        )

        // Bulunan benzersiz URL'leri toplamak için bir Set kullanıyoruz.
        var discoveredURLs = Set<URL>()

        // Adım 2: Spotlight (mdfind) Katmanı
        let spotlightURLs = try await runMdfind(bundleID: bundleID)
        discoveredURLs.formUnion(spotlightURLs)

        // Adım 3: Fallback FileManager Taraması
        let fallbackURLs = try scanFallbackDirectories(appUrl: appUrl, bundleID: bundleID)
        discoveredURLs.formUnion(fallbackURLs)

        // Adım 4: pkgutil Makbuz (Receipt) Taraması
        let pkgURLs = try await runPkgutilSearch(bundleID: bundleID)
        discoveredURLs.formUnion(pkgURLs)

        // Adım 5: Darwin Dynamic Cache/Temp Taraması (/private/var/folders/)
        let darwinCacheFiles = try await scanDarwinFolders(bundleID: bundleID)

        // Adım 6: Crash & Logs Taraması (DiagnosticReports & CrashReporter)
        let crashLogFiles = try scanCrashAndLogDirectories(appUrl: appUrl, bundleID: bundleID)

        // Ana .app paketinin kendisini yan dosyalardan çıkar (en başa tekil olarak eklenecek)
        discoveredURLs.remove(appUrl)

        // Darwin cache dosyalarının URL'lerini de discoveredURLs'ten çıkar (mükerrer olmasın)
        for darwinFile in darwinCacheFiles {
            discoveredURLs.remove(darwinFile.url)
        }

        // Crash & Log dosyalarının URL'lerini de discoveredURLs'ten çıkar (mükerrer olmasın ve .safeToDelete korunsun)
        for crashFile in crashLogFiles {
            discoveredURLs.remove(crashFile.url)
        }

        // Bulunan her URL için ScannedFile objesi oluştur (mdfind ve FileManager fallback standart aramaları -> .standard)
        let scannedFiles = discoveredURLs.map { url in
            ScannedFile(
                id: UUID(),
                url: url,
                size: fileSize(at: url),
                fileType: inferFileType(from: url),
                riskLevel: .unknown,             // Doğrulama yapılamadığı için KESİNLİKLE .unknown
                relatedBundleID: bundleID,
                discoveryMethod: .standard,
                reasoningText: nil,
                isSelectedForDeletion: false      // .unknown risk → KESİNLİKLE false
            )
        }

        var allResults = [mainAppScannedFile] + darwinCacheFiles + crashLogFiles + scannedFiles

        // Adım 7: Gelişmiş Tarama Protokolleri (advanced_protocols.md)
        if isAdvancedModeEnabled {
            async let teamIDTask = scanTeamIDGroupContainers(appUrl: appUrl, bundleID: bundleID)
            async let btmTask = scanBTM(bundleID: bundleID)
            async let extensionTask = scanSystemExtensions(bundleID: bundleID)
            async let heuristicTask = scanHeuristics(appUrl: appUrl, bundleID: bundleID)
            async let overrideTask = scanOverrides(bundleID: bundleID)

            let (teamIDFiles, btmFiles, extensionFiles, heuristicFiles, overrideFiles) = await (
                teamIDTask,
                btmTask,
                extensionTask,
                heuristicTask,
                overrideTask
            )

            let advancedFiles = teamIDFiles + btmFiles + extensionFiles + heuristicFiles + overrideFiles

            var existingIndexByPath: [String: Int] = [:]
            for (index, file) in allResults.enumerated() {
                existingIndexByPath[file.url.standardizedFileURL.path] = index
            }

            for advFile in advancedFiles {
                let path = advFile.url.standardizedFileURL.path
                if let existingIndex = existingIndexByPath[path] {
                    // Eğer dosya heuristicOverride ile gelmişse, genel aramayı override et
                    if advFile.discoveryMethod == .heuristicOverride {
                        allResults[existingIndex] = advFile
                    }
                } else {
                    existingIndexByPath[path] = allResults.count
                    allResults.append(advFile)
                }
            }
        }

        // Adım 8: Parent-Child Klasör Çakışması & Override İzolasyonu (Deduplication)
        // Eğer listede bir "Üst Klasör" VE bu klasörün içinde bir "Alt Klasör/Dosya" birlikte bulunuyorsa,
        // özellikle .heuristicOverride alt klasörlerinin üst klasörü KESİNLİKLE .highRisk ve isSelectedForDeletion = false yapılır.
        let resolvedResults = resolveParentChildCollisions(in: allResults, appUrl: appUrl)

        // UI Güvenlik Bariyeri: riskLevel değeri .safeToDelete olmayan HİÇBİR klasör varsayılan olarak seçili başlatılamaz.
        return resolvedResults.map { file in
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

    // MARK: - Adım 1: CFBundleIdentifier Çıkarımı

    /// `.app/Contents/Info.plist` dosyasından `CFBundleIdentifier` değerini okur.
    private func extractBundleIdentifier(from appUrl: URL) throws -> String {
        let plistURL = appUrl
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")

        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw ScannerError.plistNotFound(plistURL)
        }

        let plistData = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw ScannerError.plistParsingFailed(plistURL)
        }

        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw ScannerError.bundleIdentifierMissing(plistURL)
        }

        return bundleID
    }

    // MARK: - Adım 2: Spotlight (mdfind) Katmanı

    /// `mdfind` ile Spotlight indeksinde bundle ID araması yapar.
    private func runMdfind(bundleID: String) async throws -> [URL] {
        let query = "kMDItemCFBundleIdentifier == '\(bundleID)'"
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: [query]
        )
        return parsePathLines(output)
    }

    // MARK: - Adım 3: Genişletilmiş Fallback FileManager Taraması

    /// Spotlight'ın atlayabildiği dizinlerde FileManager ile 1. seviye (shallow) alt klasörleri
    /// ve üretici (Vendor) klasörlerinin 1 alt seviyesini (sub-level) case-insensitive & prefix kurallarıyla tarar.
    private func scanFallbackDirectories(appUrl: URL, bundleID: String) throws -> [URL] {
        let homeDir = fileManager.homeDirectoryForCurrentUser

        // Hedef uygulamanın isminden boşluklu ve boşluksuz versiyonları türet
        let appNameWithSpaces = appUrl.deletingPathExtension().lastPathComponent
        let appNameWithoutSpaces = appNameWithSpaces.replacingOccurrences(of: " ", with: "")

        // CFBundleIdentifier'ın ikinci segmenti -> Vendor Adı (Örn: com.riotgames.leagueoflegends -> riotgames)
        let segments = bundleID.components(separatedBy: ".")
        let vendorName: String? = segments.count >= 2 ? segments[1] : nil

        let userCachesDirectory = homeDir.appendingPathComponent("Library/Caches")
        let userContainersDirectory = homeDir.appendingPathComponent("Library/Containers")
        let userApplicationScriptsDirectory = homeDir.appendingPathComponent("Library/Application Scripts")
        let userDiagnosticReportsDirectory = homeDir.appendingPathComponent("Library/Logs/DiagnosticReports")
        let userCrashReporterDirectory = homeDir.appendingPathComponent("Library/Application Support/CrashReporter")

        let targetDirectories: [URL] = [
            homeDir.appendingPathComponent("Library/Application Support"),
            userCachesDirectory,
            homeDir.appendingPathComponent("Library/Preferences"),
            homeDir.appendingPathComponent("Library/Logs"),
            userDiagnosticReportsDirectory,
            userCrashReporterDirectory,
            userContainersDirectory,
            userApplicationScriptsDirectory,
            homeDir.appendingPathComponent("Library/Saved Application State"),
            homeDir.appendingPathComponent("Library/WebKit"),
            homeDir.appendingPathComponent("Library/HTTPStorages"),
        ]

        var results: [URL] = []

        for directory in targetDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            // DiagnosticReports ve CrashReporter dizinleri scanCrashAndLogDirectories() içinde .safeToDelete olarak doğrudan taranır
            if directory.standardizedFileURL.path == userDiagnosticReportsDirectory.standardizedFileURL.path ||
               directory.standardizedFileURL.path == userCrashReporterDirectory.standardizedFileURL.path {
                continue
            }

            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [] // .skipsHiddenFiles KESİNLİKLE devre dışı
                )
            } catch {
                // İzin hatası (Permission Denied) durumunda açıkça Error fırlat
                throw ScannerError.permissionDenied(directory, error)
            }

            let isExtensionDirectory = directory.standardizedFileURL.path == userContainersDirectory.standardizedFileURL.path ||
                                       directory.standardizedFileURL.path == userApplicationScriptsDirectory.standardizedFileURL.path

            for itemURL in contents {
                let itemName = itemURL.lastPathComponent
                let lowerItemName = itemName.lowercased()
                let lowerBundleID = bundleID.lowercased()

                // 1. App Extension (Suffix) Eşleştirme Mantığı:
                // Containers ve Application Scripts klasörlerinde ana Bundle ID'lerin sonuna
                // .FinderSync, .FinderOpen, .ShareExtension gibi ekler gelebilir.
                // Klasör adı ana Bundle ID ile başlıyorsa (hasPrefix) doğrudan geçerli kabul edilir.
                if isExtensionDirectory && (lowerItemName.hasPrefix(lowerBundleID) || itemName.hasPrefix(bundleID)) {
                    results.append(itemURL)
                    continue
                }

                // 2. Doğrudan bu uygulamaya ait bir dosya/klasör mü? (Prefix veya Contains eşleşmesi)
                if matchesDirectAppCandidate(
                    name: itemName,
                    bundleID: bundleID,
                    appNameWithSpaces: appNameWithSpaces,
                    appNameWithoutSpaces: appNameWithoutSpaces
                ) {
                    results.append(itemURL)
                }

                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                // 2. Üçüncü Parti Framework (Sentry vb.) Önbellek Taraması:
                // Sadece ~/Library/Caches/ dizinine ÖZEL olmak üzere:
                // ~/Library/Caches/ altındaki BÜTÜN birinci seviye klasörlerin (isimleri Vendor ile eşleşmese bile, örn: SentryCrash)
                // doğrudan BİR KATMAN İÇİNE GİR ve taranan uygulamanın Bundle ID'si veya adı ile eşleşenleri bul.
                // DİKKAT: Sadece 1 katman derinlikte aranır, asla sınırsız recursive yapılmaz.
                if directory.standardizedFileURL.path == userCachesDirectory.standardizedFileURL.path {
                    if let subContents = try? fileManager.contentsOfDirectory(
                        at: itemURL,
                        includingPropertiesForKeys: nil,
                        options: []
                    ) {
                        for subURL in subContents {
                            let subName = subURL.lastPathComponent
                            if matchesDirectAppCandidate(
                                name: subName,
                                bundleID: bundleID,
                                appNameWithSpaces: appNameWithSpaces,
                                appNameWithoutSpaces: appNameWithoutSpaces
                            ) {
                                results.append(subURL)
                            }
                        }
                    }
                } else {
                    // 3. Vendor (Üretici) Derinlik Katmanı (Caches dışındaki dizinler için):
                    // Klasör adı Vendor adını (boşluklu veya boşluksuz) içeriyorsa 1 alt kademesine in
                    if matchesVendor(name: itemName, vendorName: vendorName) {
                        if let subContents = try? fileManager.contentsOfDirectory(
                            at: itemURL,
                            includingPropertiesForKeys: nil,
                            options: []
                        ) {
                            for subURL in subContents {
                                let subName = subURL.lastPathComponent
                                if matchesDirectAppCandidate(
                                    name: subName,
                                    bundleID: bundleID,
                                    appNameWithSpaces: appNameWithSpaces,
                                    appNameWithoutSpaces: appNameWithoutSpaces
                                ) {
                                    results.append(subURL)
                                }
                            }
                        }
                    }
                }
            }
        }

        return results
    }

    /// Dosya veya klasör adının doğrudan hedef uygulamaya ait olup olmadığını kontrol eder.
    /// KESİNLİKLE büyük/küçük harf duyarsızdır (.lowercased()).
    /// Tam eşleşmenin yanı sıra, Bundle ID veya uygulama adıyla BAŞLAMA (hasPrefix) veya İÇERME (contains) kurallarını uygular.
    private func matchesDirectAppCandidate(
        name: String,
        bundleID: String,
        appNameWithSpaces: String,
        appNameWithoutSpaces: String
    ) -> Bool {
        let lowerName = name.lowercased()
        let lowerBundleID = bundleID.lowercased()
        let lowerNameWithoutSpaces = lowerName.replacingOccurrences(of: " ", with: "")

        // 1. Bundle ID ile başlangıç (hasPrefix) veya içerme (contains)
        // Örn: com.riotgames.LeagueofLegends.LeagueClientUxHelper.plist
        if lowerName.hasPrefix(lowerBundleID) || lowerName.contains(lowerBundleID) {
            return true
        }

        // 2. Türetilmiş uygulama adı ile başlangıç (hasPrefix) veya içerme (contains)
        // Boşluklu isim (örn: "league of legends")
        let lowerWithSpaces = appNameWithSpaces.lowercased()
        if !lowerWithSpaces.isEmpty {
            if lowerName.hasPrefix(lowerWithSpaces) || lowerName.contains(lowerWithSpaces) {
                return true
            }
        }

        // Boşluksuz isim (örn: "leagueoflegends")
        let lowerWithoutSpaces = appNameWithoutSpaces.lowercased()
        if !lowerWithoutSpaces.isEmpty {
            if lowerNameWithoutSpaces.hasPrefix(lowerWithoutSpaces) || lowerNameWithoutSpaces.contains(lowerWithoutSpaces) {
                return true
            }
        }

        // 3. Gizli Dosyalar (Dotfiles): .android, .gradle, .npm vb.
        if name.hasPrefix(".") {
            let cleanDotName = String(lowerName.dropFirst())
            if cleanDotName.count >= 3 {
                let segments = lowerBundleID.components(separatedBy: ".")
                if segments.contains(cleanDotName) || lowerBundleID.contains(cleanDotName) {
                    return true
                }

                let isAndroidApp = lowerBundleID.contains("android") || lowerWithSpaces.contains("android")
                if isAndroidApp && (cleanDotName == "gradle" || cleanDotName == "android") {
                    return true
                }

                let webKeywords = ["npm", "node", "javascript", "typescript", "electron", "postman", "vscode"]
                if webKeywords.contains(where: { lowerBundleID.contains($0) || lowerWithSpaces.contains($0) }) {
                    if cleanDotName == "npm" || cleanDotName == "yarn" {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Klasör adının üretici (Vendor) adını (boşluklu veya boşluksuz) içerip içermediğini kontrol eder.
    /// Örn: Vendor "riotgames" -> Klasör "Riot Games" veya "riotgames"
    private func matchesVendor(name: String, vendorName: String?) -> Bool {
        guard let vendor = vendorName, vendor.count >= 3 else { return false }
        let lowerName = name.lowercased()
        let lowerVendor = vendor.lowercased()
        let lowerNameWithoutSpaces = lowerName.replacingOccurrences(of: " ", with: "")
        let lowerVendorWithoutSpaces = lowerVendor.replacingOccurrences(of: " ", with: "")

        return lowerName.contains(lowerVendor) ||
               lowerNameWithoutSpaces.contains(lowerVendorWithoutSpaces) ||
               lowerVendorWithoutSpaces.contains(lowerNameWithoutSpaces)
    }

    // MARK: - Adım 4: pkgutil Makbuz (Receipt) Taraması

    /// `pkgutil --pkgs` çıktısında bundle ID ile eşleşen paketleri bulur,
    /// ardından `pkgutil --files` ile her paketin dosyalarını listeler.
    private func runPkgutilSearch(bundleID: String) async throws -> [URL] {
        // Tüm kayıtlı paketleri listele
        let allPackagesOutput = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
            arguments: ["--pkgs"]
        )

        let allPackages = allPackagesOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Bundle ID ile eşleşen paketleri filtrele
        let matchingPackages = allPackages.filter { $0.contains(bundleID) }

        var results: [URL] = []

        for package in matchingPackages {
            let filesOutput = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
                arguments: ["--files", package]
            )

            let filePaths = filesOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for relativePath in filePaths {
                // pkgutil göreceli yollar döner; kök dizine göre mutlak yol oluştur
                let absoluteURL = URL(fileURLWithPath: "/\(relativePath)")
                if fileManager.fileExists(atPath: absoluteURL.path) {
                    results.append(absoluteURL)
                }
            }
        }

        return results
    }

    // MARK: - Adım 5: Darwin Dynamic Cache/Temp Taraması (/private/var/folders/)

    /// getconf DARWIN_USER_CACHE_DIR ve getconf DARWIN_USER_TEMP_DIR shell komutlarını çalıştırarak
    /// /private/var/folders/.../C/ ve .../T/ dizinlerinin 1. seviye (shallow) içeriğini okur.
    /// Hedef Bundle ID ile tam eşleşen veya onunla başlayan (.hasPrefix, örn: helper, renderer) klasörleri tespit eder.
    private func scanDarwinFolders(bundleID: String) async throws -> [ScannedFile] {
        let getconfURL = URL(fileURLWithPath: "/usr/bin/getconf")

        let cacheDirOutput = try await runProcess(
            executableURL: getconfURL,
            arguments: ["DARWIN_USER_CACHE_DIR"]
        )
        let tempDirOutput = try await runProcess(
            executableURL: getconfURL,
            arguments: ["DARWIN_USER_TEMP_DIR"]
        )

        let rawPaths = [
            cacheDirOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            tempDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }

        var foundFiles: [ScannedFile] = []
        var checkedURLs = Set<URL>()
        let lowerBundleID = bundleID.lowercased()

        for basePath in rawPaths {
            let baseDirURL = URL(fileURLWithPath: basePath)
            guard fileManager.fileExists(atPath: baseDirURL.path) else { continue }

            // 1. Seviye (shallow) doğrudan içini oku; tüm sistemi kilitlememek için recursive enumerator kullanılmaz
            guard let contents = try? fileManager.contentsOfDirectory(
                at: baseDirURL,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }

            for itemURL in contents {
                guard !checkedURLs.contains(itemURL) else { continue }
                let itemName = itemURL.lastPathComponent
                let lowerItemName = itemName.lowercased()

                // Klasör adı hedefin Bundle ID'si ile başlıyor mu? (.hasPrefix)
                guard itemName.hasPrefix(bundleID) || lowerItemName.hasPrefix(lowerBundleID) else {
                    continue
                }

                checkedURLs.insert(itemURL)

                // Tam eşleşme mi yoksa suffix (helper/renderer vb.) mi?
                let isExactMatch = (itemName == bundleID || lowerItemName == lowerBundleID)
                let risk: RiskLevel = isExactMatch ? .safeToDelete : .unknown
                let isSelected: Bool = isExactMatch ? true : false
                let reasoning: String = isExactMatch
                    ? "Darwin dinamik önbellek klasörü (tam bundle ID eşleşmesi)"
                    : "Darwin dinamik alt/yan süreç klasörü (suffix eşleşmesi: \(itemName))"

                let file = ScannedFile(
                    id: UUID(),
                    url: itemURL,
                    size: fileSize(at: itemURL),
                    fileType: inferFileType(from: itemURL),
                    riskLevel: risk,
                    relatedBundleID: bundleID,
                    discoveryMethod: .standard,
                    reasoningText: reasoning,
                    isSelectedForDeletion: isSelected
                )
                foundFiles.append(file)
            }
        }

        return foundFiles
    }

    // MARK: - Adım 6: Crash & Logs Taraması (DiagnosticReports & CrashReporter)

    /// ~/Library/Logs/DiagnosticReports/ ve ~/Library/Application Support/CrashReporter/ dizinlerinde
    /// doğrudan 1. seviye tarama yapar. Dosya adlarında hedef uygulamanın adı (örn: steam) VEYA Bundle ID'si geçiyorsa
    /// (.contains veya .hasPrefix ile), bu dosyaları [ScannedFile] listesine
    /// riskLevel: .safeToDelete ve discoveryMethod: .standard olarak ekler.
    private func scanCrashAndLogDirectories(appUrl: URL, bundleID: String) throws -> [ScannedFile] {
        let homeDir = fileManager.homeDirectoryForCurrentUser

        let appName = appUrl.deletingPathExtension().lastPathComponent
        let lowerAppName = appName.lowercased()
        let appNameWithoutSpaces = appName.replacingOccurrences(of: " ", with: "").lowercased()
        let lowerBundleID = bundleID.lowercased()

        let appWords = lowerAppName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }

        let crashDirectories: [URL] = [
            homeDir.appendingPathComponent("Library/Logs/DiagnosticReports"),
            homeDir.appendingPathComponent("Library/Application Support/CrashReporter")
        ]

        var foundFiles: [ScannedFile] = []
        var checkedURLs = Set<URL>()

        for directory in crashDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw ScannerError.permissionDenied(directory, error)
            }

            for itemURL in contents {
                guard !checkedURLs.contains(itemURL) else { continue }
                let itemName = itemURL.lastPathComponent
                let lowerItemName = itemName.lowercased()

                // Dosya adlarında hedef uygulamanın adı (örn: steam) VEYA Bundle ID'si geçiyorsa (.contains veya .hasPrefix ile)
                let matchesAppName = lowerItemName.hasPrefix(lowerAppName) ||
                                     lowerItemName.contains(lowerAppName) ||
                                     lowerItemName.hasPrefix(appNameWithoutSpaces) ||
                                     lowerItemName.contains(appNameWithoutSpaces) ||
                                     appWords.contains(where: { lowerItemName.contains($0) })

                let matchesBundleID = lowerItemName.hasPrefix(lowerBundleID) ||
                                      lowerItemName.contains(lowerBundleID)

                if matchesAppName || matchesBundleID {
                    checkedURLs.insert(itemURL)
                    let file = ScannedFile(
                        id: UUID(),
                        url: itemURL,
                        size: fileSize(at: itemURL),
                        fileType: inferFileType(from: itemURL),
                        riskLevel: .safeToDelete,
                        relatedBundleID: bundleID,
                        discoveryMethod: .standard,
                        reasoningText: "Crash & Log raporu (\(directory.lastPathComponent))",
                        isSelectedForDeletion: true
                    )
                    foundFiles.append(file)
                }
            }
        }

        return foundFiles
    }

    // MARK: - Gelişmiş Vektör 1: Team ID & Group Containers

    /// codesign veya Info.plist üzerinden TeamIdentifier okur ve ~/Library/Group Containers/ altında
    /// Team ID ile başlayan klasörleri .sharedDependency olarak ekler.
    private func scanTeamIDGroupContainers(appUrl: URL, bundleID: String) async -> [ScannedFile] {
        var foundFiles: [ScannedFile] = []
        var teamID: String? = nil

        // 1. codesign -dv --verbose=4 <appUrl>
        do {
            let output = try await runProcessCombined(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["-dv", "--verbose=4", appUrl.path]
            )
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("TeamIdentifier=") {
                    let id = String(trimmed.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
                    if !id.isEmpty && id != "not set" {
                        teamID = id
                        break
                    }
                }
            }
        } catch {}

        // Fallback: Info.plist
        if teamID == nil {
            let plistURL = appUrl.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                teamID = plist["TeamIdentifier"] as? String ?? plist["AppIdentifierPrefix"] as? String
            }
        }

        guard let extractedTeamID = teamID, !extractedTeamID.isEmpty else {
            return []
        }

        let homeDir = fileManager.homeDirectoryForCurrentUser
        let groupContainersURL = homeDir.appendingPathComponent("Library/Group Containers")
        guard fileManager.fileExists(atPath: groupContainersURL.path) else { return [] }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: groupContainersURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }

        for itemURL in contents {
            let folderName = itemURL.lastPathComponent
            if folderName.hasPrefix(extractedTeamID) {
                let file = ScannedFile(
                    id: UUID(),
                    url: itemURL,
                    size: fileSize(at: itemURL),
                    fileType: .container,
                    riskLevel: .sharedDependency,
                    relatedBundleID: bundleID,
                    discoveryMethod: .teamID,
                    reasoningText: "Team ID (\(extractedTeamID)) ile eşleşen Group Container",
                    isSelectedForDeletion: false
                )
                foundFiles.append(file)
            }
        }

        return foundFiles
    }

    // MARK: - Gelişmiş Vektör 2: BTM (Background Task Management)

    /// `sfltool dumpbtm` komutunu çalıştırarak hedef Bundle ID ile ilişkili servis kayıtlarını çıkarır.
    private func scanBTM(bundleID: String) async -> [ScannedFile] {
        var foundFiles: [ScannedFile] = []
        let output: String
        do {
            output = try await runProcessCombined(
                executableURL: URL(fileURLWithPath: "/usr/bin/sfltool"),
                arguments: ["dumpbtm"]
            )
        } catch {
            return []
        }

        let lowerBundleID = bundleID.lowercased()
        let lines = output.components(separatedBy: .newlines)
        var currentBlock: [String] = []
        var blocks: [[String]] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && trimmed.contains(":") {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = []
                }
            }
            currentBlock.append(trimmed)
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        var candidatePaths = Set<String>()

        for block in blocks {
            let blockText = block.joined(separator: "\n").lowercased()
            guard blockText.contains(lowerBundleID) else { continue }

            for line in block {
                if line.hasPrefix("URL:") {
                    var pathValue = String(line.dropFirst("URL:".count)).trimmingCharacters(in: .whitespaces)
                    if pathValue.hasPrefix("file://") {
                        if let u = URL(string: pathValue) {
                            pathValue = u.path
                        }
                    }
                    if pathValue != "(null)" && !pathValue.isEmpty {
                        candidatePaths.insert(pathValue)
                    }
                } else if line.hasPrefix("Executable Path:") {
                    let pathValue = String(line.dropFirst("Executable Path:".count)).trimmingCharacters(in: .whitespaces)
                    if pathValue != "(null)" && !pathValue.isEmpty {
                        candidatePaths.insert(pathValue)
                    }
                }
            }
        }

        for path in candidatePaths {
            guard fileManager.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            let file = ScannedFile(
                id: UUID(),
                url: url,
                size: fileSize(at: url),
                fileType: inferFileType(from: url),
                riskLevel: .highRisk,
                relatedBundleID: bundleID,
                discoveryMethod: .btm,
                reasoningText: "sfltool BTM arka plan servisi kaydı",
                isSelectedForDeletion: false
            )
            foundFiles.append(file)
        }

        return foundFiles
    }

    // MARK: - Gelişmiş Vektör 3: System Extensions

    /// `systemextensionsctl list` komutunu çalıştırarak sistem eklentilerini tespit eder.
    private func scanSystemExtensions(bundleID: String) async -> [ScannedFile] {
        var foundFiles: [ScannedFile] = []
        let output: String
        do {
            output = try await runProcessCombined(
                executableURL: URL(fileURLWithPath: "/usr/bin/systemextensionsctl"),
                arguments: ["list"]
            )
        } catch {
            return []
        }

        let lowerBundleID = bundleID.lowercased()
        guard output.lowercased().contains(lowerBundleID) else { return [] }

        let targetDirs = [
            URL(fileURLWithPath: "/Library/SystemExtensions"),
            URL(fileURLWithPath: "/Library/DriverExtensions"),
            URL(fileURLWithPath: "/Library/Extensions")
        ]

        var checkedURLs = Set<URL>()

        for dir in targetDirs {
            guard fileManager.fileExists(atPath: dir.path),
                  let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else {
                continue
            }

            for item in contents {
                let name = item.lastPathComponent.lowercased()
                if name.contains(lowerBundleID) {
                    if !checkedURLs.contains(item) {
                        checkedURLs.insert(item)
                        let file = ScannedFile(
                            id: UUID(),
                            url: item,
                            size: fileSize(at: item),
                            fileType: .unknown,
                            riskLevel: .highRisk,
                            relatedBundleID: bundleID,
                            discoveryMethod: .extension,
                            reasoningText: "systemextensionsctl ile eşleşen sistem eklentisi",
                            isSelectedForDeletion: false
                        )
                        foundFiles.append(file)
                    }
                }
            }
        }

        return foundFiles
    }

    // MARK: - Gelişmiş Vektör 4: Statik Heuristic Database

    /// `heuristics.json` veritabanındaki statik kural eşleşmelerini kontrol eder.
    /// Anahtar (Key) olarak Bundle ID yerine .app dosya adı (uzantısız, boşluklar tireye çevrilmiş, küçük harf) kullanılır.
    /// Örn: "Google Chrome.app" -> "google-chrome"
    private func scanHeuristics(appUrl: URL, bundleID: String) async -> [ScannedFile] {
        let heuristicsDB = loadHeuristicsDatabase()

        // 1. JSON Key Eşleştirmesi: Hedefin .app dosya adından anahtar türet (Örn: "Google Chrome.app" -> "google-chrome")
        let appFileName = appUrl.deletingPathExtension().lastPathComponent
        let tokenizedKey = appFileName.replacingOccurrences(of: " ", with: "-").lowercased()

        guard let paths = heuristicsDB[tokenizedKey] ?? heuristicsDB.first(where: { $0.key.lowercased() == tokenizedKey })?.value else {
            return []
        }

        // 2. Tilde Genişletmesi: (NSHomeDirectory() as NSString) ile mutlak fiziksel yola çevir
        let homeDir = NSHomeDirectory()
        var foundFiles: [ScannedFile] = []

        for rawPath in paths {
            let expandedPath: String
            if rawPath.hasPrefix("~/") {
                expandedPath = (homeDir as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
            } else if rawPath == "~" {
                expandedPath = homeDir
            } else {
                expandedPath = (rawPath as NSString).expandingTildeInPath
            }

            // Yalnızca tam fiziksel yolda dosya/klasör bulunursa listeye ekle
            guard fileManager.fileExists(atPath: expandedPath) else { continue }
            let url = URL(fileURLWithPath: expandedPath)

            // 3. Tahribat Engeli ve UI Bariyeri: riskLevel: .unknown, discoveryMethod: .heuristic, isSelectedForDeletion: false
            let file = ScannedFile(
                id: UUID(),
                url: url,
                size: fileSize(at: url),
                fileType: inferFileType(from: url),
                riskLevel: .unknown,
                relatedBundleID: bundleID,
                discoveryMethod: .heuristic,
                reasoningText: "heuristics.json kural tabanlı eşleşme (\(tokenizedKey))",
                isSelectedForDeletion: false
            )
            foundFiles.append(file)
        }

        return foundFiles
    }

    private func loadHeuristicsDatabase() -> [String: [String]] {
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceFileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        let candidates: [URL?] = [
            Bundle.main.url(forResource: "heuristics", withExtension: "json"),
            sourceFileDir.appendingPathComponent("heuristics.json"),
            currentDir.appendingPathComponent("heuristics.json"),
            currentDir.appendingPathComponent("my_little_mac/heuristics.json"),
            currentDir.appendingPathComponent("my_little_mac/Resources/heuristics.json")
        ]

        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
                return dict
            }
        }
        return [:]
    }

    // MARK: - Gelişmiş Vektör 5: Heuristic Overrides (Spesifik Alt Klasörler)

    /// `overrides.json` veritabanındaki Bundle ID bazlı statik kural eşleşmelerini kontrol eder.
    /// Format: [String: [String]] (Key: Bundle ID, Value: Alt klasör yolları).
    /// Keşfedilen dosyalar KESİNLİKLE .safeToDelete ve .heuristicOverride olarak işaretlenir.
    private func scanOverrides(bundleID: String) async -> [ScannedFile] {
        let overridesDB = loadOverridesDatabase()

        // 1. JSON Key Eşleştirmesi: Bundle ID ile tam veya case-insensitive eşleşme ara
        let lowerBundleID = bundleID.lowercased()
        guard let paths = overridesDB[bundleID] ?? overridesDB.first(where: { $0.key.lowercased() == lowerBundleID })?.value else {
            return []
        }

        // 2. Tilde Genişletmesi ve Fiziksel Varlık Kontrolü
        let homeDir = NSHomeDirectory()
        var foundFiles: [ScannedFile] = []

        for rawPath in paths {
            let expandedPath: String
            if rawPath.hasPrefix("~/") {
                expandedPath = (homeDir as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
            } else if rawPath == "~" {
                expandedPath = homeDir
            } else {
                expandedPath = (rawPath as NSString).expandingTildeInPath
            }

            // Yalnızca tam fiziksel yolda dosya/klasör bulunursa listeye ekle
            guard fileManager.fileExists(atPath: expandedPath) else { continue }
            let url = URL(fileURLWithPath: expandedPath)

            // 3. Veri Protokolü: discoveryMethod: .heuristicOverride, riskLevel: .safeToDelete, isSelectedForDeletion: true
            let file = ScannedFile(
                id: UUID(),
                url: url,
                size: fileSize(at: url),
                fileType: inferFileType(from: url),
                riskLevel: .safeToDelete,
                relatedBundleID: bundleID,
                discoveryMethod: .heuristicOverride,
                reasoningText: "overrides.json kural tabanlı spesifik alt klasör eşleşmesi (\(bundleID))",
                isSelectedForDeletion: true
            )
            foundFiles.append(file)
        }

        return foundFiles
    }

    private func loadOverridesDatabase() -> [String: [String]] {
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceFileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        let candidates: [URL?] = [
            Bundle.main.url(forResource: "overrides", withExtension: "json"),
            sourceFileDir.appendingPathComponent("overrides.json"),
            currentDir.appendingPathComponent("overrides.json"),
            currentDir.appendingPathComponent("my_little_mac/overrides.json"),
            currentDir.appendingPathComponent("my_little_mac/Resources/overrides.json")
        ]

        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
                return dict
            }
        }
        return [:]
    }

    // MARK: - Adım 8: Parent-Child Klasör Çakışması & Override İzolasyonu (Deduplication)

    /// Eğer listede bir "Üst Klasör" (Örn: ~/Library/Application Support/Steam) VE aynı zamanda bu klasörün
    /// içindeki bir "Alt Klasör/Dosya" (Örn: ~/Library/Application Support/Steam/appcache) birlikte bulunuyorsa:
    /// Üst klasörün riskLevel değerini KESİNLİKLE .highRisk (Kod: 2) olarak zorlar ve isSelectedForDeletion = false yapar.
    /// Böylece güvenli alt klasörler silinmeye hazır (seçili) kalırken, kullanıcı verisi barındıran ana klasör kilitlenir.
    private func resolveParentChildCollisions(in files: [ScannedFile], appUrl: URL) -> [ScannedFile] {
        let standardizedPaths = files.map { $0.url.standardizedFileURL.path }
        let standardizedAppPath = appUrl.standardizedFileURL.path

        // .heuristicOverride ile gelen alt dosyaların standart yolları
        let overrideChildPaths = files
            .filter { $0.discoveryMethod == .heuristicOverride }
            .map { $0.url.standardizedFileURL.path }

        return files.map { file in
            let parentPath = file.url.standardizedFileURL.path

            // Ana .app paketinin kendisi doğrudan hedef uygulama olduğundan bu kuraldan muaf tutulur
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
                    riskLevel: .highRisk, // KESİNLİKLE .highRisk (Kod: 2)
                    relatedBundleID: file.relatedBundleID,
                    discoveryMethod: file.discoveryMethod,
                    reasoningText: "Güvenli alt klasörler (.heuristicOverride) bağımsız hedeflendiğinden üst klasör kullanıcı verilerini korumak amacıyla yüksek riskli (.highRisk) olarak kilitlendi",
                    isSelectedForDeletion: false // UI Güvenlik Bariyeri: KESİNLİKLE false
                )
            }

            // 2. Genel parent-child çakışması (Deduplication):
            let hasChildInList = standardizedPaths.contains { childPath in
                childPath != parentPath && childPath.hasPrefix(parentPathWithSlash)
            }

            if hasChildInList {
                return ScannedFile(
                    id: file.id,
                    url: file.url,
                    size: file.size,
                    fileType: file.fileType,
                    riskLevel: .highRisk, // KESİNLİKLE .highRisk (Kod: 2)
                    relatedBundleID: file.relatedBundleID,
                    discoveryMethod: file.discoveryMethod,
                    reasoningText: "Alt klasör/dosyaları bağımsız olarak listelendiğinden üst klasör yüksek riskli (.highRisk) olarak kilitlendi",
                    isSelectedForDeletion: false // UI Güvenlik Bariyeri: KESİNLİKLE false
                )
            }

            return file
        }
    }

    // MARK: - Yardımcı: stdout + stderr Birleşik Process Çalıştırma

    /// Komut çıktısını hem stdout hem stderr birleştirilmiş olarak asenkron döner.
    private func runProcessCombined(executableURL: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Yardımcı: Process Çalıştırma (async)

    /// Verilen komut satırı aracını asenkron olarak çalıştırır ve stdout çıktısını döner.
    private func runProcess(executableURL: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe

            process.terminationHandler = { proc in
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus != 0 {
                    let execName = executableURL.lastPathComponent
                    let message = errorOutput.isEmpty
                        ? "\(execName) komutu \(proc.terminationStatus) çıkış koduyla başarısız oldu."
                        : errorOutput
                    continuation.resume(throwing: ScannerError.commandExecutionFailed(executable: execName, exitCode: proc.terminationStatus, message: message))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ScannerError.processLaunchFailed(error))
            }
        }
    }

    // MARK: - Yardımcı: Çıktı Ayrıştırma

    /// Satır satır gelen yol çıktısını `[URL]` dizisine dönüştürür.
    private func parsePathLines(_ output: String) -> [URL] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Yardımcı: Dosya Boyutu

    /// Dosyanın veya klasörün bayt cinsinden toplam boyutunu hesaplar.
    private func fileSize(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
                options: [] // .skipsHiddenFiles devre dışı
            ) else {
                return 0
            }

            var totalSize: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]),
                   let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileSize {
                    totalSize += Int64(size)
                }
            }
            return totalSize
        } else {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else {
                return 0
            }
            return size
        }
    }

    // MARK: - Yardımcı: FileType Çıkarımı

    /// Dosya yoluna bakarak yüzeysel `FileType` ataması yapar.
    private func inferFileType(from url: URL) -> FileType {
        let path = url.path

        if path.hasSuffix(".app") {
            return .appBundle
        } else if path.contains("/LaunchDaemons/") {
            return .launchDaemon
        } else if path.contains("/LaunchAgents/") {
            return .launchAgent
        } else if path.contains("/Caches/") || path.contains("/var/folders/") || path.contains("/WebKit/") || path.contains("/HTTPStorages/") {
            return .cache
        } else if path.contains("/Preferences/") {
            return .preference
        } else if path.contains("/Group Containers/") {
            return .container
        } else if path.hasPrefix("/var/db/receipts/") {
            return .pkgReceipt
        } else if url.lastPathComponent.hasPrefix(".") {
            return .hiddenDotfile
        }

        return .unknown
    }
}

// MARK: - Scanner Hataları

enum ScannerError: LocalizedError {
    case plistNotFound(URL)
    case plistParsingFailed(URL)
    case bundleIdentifierMissing(URL)
    case processLaunchFailed(Error)
    case commandExecutionFailed(executable: String, exitCode: Int32, message: String)
    case permissionDenied(URL, Error)

    var errorDescription: String? {
        switch self {
        case .plistNotFound(let url):
            return "Info.plist bulunamadı: \(url.path)"
        case .plistParsingFailed(let url):
            return "Info.plist okunamadı: \(url.path)"
        case .bundleIdentifierMissing(let url):
            return "CFBundleIdentifier değeri bulunamadı: \(url.path)"
        case .processLaunchFailed(let error):
            return "Süreç başlatılamadı: \(error.localizedDescription)"
        case .commandExecutionFailed(let executable, let exitCode, let message):
            return "\(executable) komutu hata verdi (çıkış kodu: \(exitCode)): \(message)"
        case .permissionDenied(let url, let error):
            return "Erişim izni reddedildi (Permission Denied): \(url.path) — \(error.localizedDescription)"
        }
    }
}
