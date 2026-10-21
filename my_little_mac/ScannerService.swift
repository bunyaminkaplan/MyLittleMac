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
    /// - Parameter appUrl: Seçilen `.app` paketinin URL'i.
    /// - Returns: Bulunan tüm ilişkili dosyaların `[ScannedFile]` listesi.
    func scan(appUrl: URL) async throws -> [ScannedFile] {

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

        // Ana .app paketinin kendisini yan dosyalardan çıkar (en başa tekil olarak eklenecek)
        discoveredURLs.remove(appUrl)

        // Darwin cache dosyalarının URL'lerini de discoveredURLs'ten çıkar (mükerrer olmasın)
        for darwinFile in darwinCacheFiles {
            discoveredURLs.remove(darwinFile.url)
        }

        // Bulunan her URL için ScannedFile objesi oluştur
        let scannedFiles = discoveredURLs.map { url in
            ScannedFile(
                id: UUID(),
                url: url,
                size: fileSize(at: url),
                fileType: inferFileType(from: url),
                riskLevel: .unknown,             // Doğrulama yapılamadığı için KESİNLİKLE .unknown
                relatedBundleID: bundleID,
                isSelectedForDeletion: false      // .unknown risk → KESİNLİKLE false
            )
        }

        // Ana uygulama en başta, ardından darwinCacheFiles ve diğer bulunan dosyalar
        return [mainAppScannedFile] + darwinCacheFiles + scannedFiles
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

        let targetDirectories: [URL] = [
            homeDir, // Kullanıcı Kök Dizini (~)
            homeDir.appendingPathComponent("Library/Application Support"),
            userCachesDirectory,
            homeDir.appendingPathComponent("Library/Preferences"),
            homeDir.appendingPathComponent("Library/Logs"),
            userContainersDirectory,
            userApplicationScriptsDirectory,
            homeDir.appendingPathComponent("Library/Saved Application State"),
            homeDir.appendingPathComponent("Library/WebKit"),
            homeDir.appendingPathComponent("Library/HTTPStorages"),
            URL(fileURLWithPath: "/Library/Application Support"),
            URL(fileURLWithPath: "/Library/Caches"),
            URL(fileURLWithPath: "/Library/Preferences"),
        ]

        var results: [URL] = []

        for directory in targetDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

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
    /// /private/var/folders/.../C/ ve .../T/ dizinlerinde taranan uygulamanın Bundle ID'si ile tam eşleşen
    /// klasörleri nokta atışı bulur. Sistemi kilitlememek için enumerator kullanılmaz.
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

        for basePath in rawPaths {
            let baseDirURL = URL(fileURLWithPath: basePath)
            let candidateURL = baseDirURL.appendingPathComponent(bundleID)

            guard !checkedURLs.contains(candidateURL) else { continue }
            checkedURLs.insert(candidateURL)

            // Hiçbir koşulda enumerator ile baştan sona tarama yapılmaz;
            // sadece getconf çıktısının sonuna Bundle ID eklenerek nokta atışı kontrol edilir.
            if fileManager.fileExists(atPath: candidateURL.path) {
                let file = ScannedFile(
                    id: UUID(),
                    url: candidateURL,
                    size: fileSize(at: candidateURL),
                    fileType: .cache,
                    riskLevel: .safeToDelete, // İsim doğrudan Bundle ID ile tam eşleştiği için safeToDelete
                    relatedBundleID: bundleID,
                    isSelectedForDeletion: true
                )
                foundFiles.append(file)
            }
        }

        return foundFiles
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
