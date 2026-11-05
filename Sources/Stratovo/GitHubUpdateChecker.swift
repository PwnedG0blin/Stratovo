import Combine
import Foundation
import StratovoCore

enum GitHubUpdateState {
    case idle
    case noReleases
    case upToDate(String?)
    case available(StratovoRelease)
    case failed(String)
}

/// Only reads the public GitHub Releases API. No GitHub account is accessed.
@MainActor
final class GitHubUpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var state: GitHubUpdateState = .idle
    @Published private(set) var lastChecked: Date?

    private var checkedThisSession = false
    private let defaults: UserDefaults
    private let lastAttemptKey = "Pixelkoje.GitHubUpdates.lastAttempt"
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    let installedVersion: String

    init(installedVersion: String? = nil, defaults: UserDefaults = .standard,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.fetch = fetch
        self.installedVersion = installedVersion ?? Bundle.main.object(forInfoDictionaryKey: "StratovoReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unbekannt"
    }

    func checkIfDue(includePrereleases: Bool) async {
        if checkedThisSession, let last = defaults.object(forKey: lastAttemptKey) as? Date,
           Date().timeIntervalSince(last) < 60 * 60 { return }
        await check(includePrereleases: includePrereleases)
    }

    func check(includePrereleases: Bool) async {
        guard !isChecking else { return }
        guard StratovoVersion(installedVersion) != nil else {
            state = .failed(L10n.text("Die installierte App-Version konnte nicht gelesen werden."))
            return
        }
        checkedThisSession = true
        isChecking = true
        defer { isChecking = false }
        // Prevent repeated automatic requests when GitHub's public rate limit is reached.
        defaults.set(Date(), forKey: lastAttemptKey)

        var request = URLRequest(url: StratovoReleaseCatalog.apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Stratovo/1.0 GitHub-Releases-Check", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            var (data, response) = try await fetch(request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                request.url = StratovoReleaseCatalog.legacyAPIURL
                (data, response) = try await fetch(request)
            }
            guard let http = response as? HTTPURLResponse else {
                state = .failed(L10n.text("Keine gültige Antwort von GitHub erhalten."))
                return
            }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 403, 429:
                    state = .failed(L10n.text("GitHub begrenzt gerade die öffentlichen API-Abfragen. Bitte später erneut prüfen."))
                case 404:
                    state = .failed(L10n.text("Die GitHub-Veröffentlichungen sind momentan nicht erreichbar."))
                default:
                    state = .failed(L10n.message("GitHub antwortet mit HTTP \(http.statusCode). Bitte später erneut prüfen."))
                }
                return
            }
            let releases = try JSONDecoder().decode([StratovoRelease].self, from: data)
            lastChecked = Date()
            if releases.isEmpty {
                state = .noReleases
            } else if let next = StratovoReleaseCatalog.newerRelease(
                in: releases, installedVersion: installedVersion, includePrereleases: includePrereleases
            ) {
                state = .available(next)
            } else {
                let latest = StratovoReleaseCatalog.latestRelease(in: releases, includePrereleases: includePrereleases)
                state = .upToDate(latest?.tagName)
            }
        } catch {
            state = .failed(L10n.text("Die GitHub-Abfrage ist fehlgeschlagen. Prüfe die Internetverbindung und versuche es erneut."))
        }
    }
}
