import SwiftUI
import Foundation
import FaviconFinder

struct ServiceSuggestion: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: String
    var faviconData: Data?
    /// True while the favicon is still being fetched from the network.
    var isLoadingFavicon: Bool = false

    static func == (lhs: ServiceSuggestion, rhs: ServiceSuggestion) -> Bool {
        return lhs.name == rhs.name && lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(url)
    }
}

@MainActor
class ServiceSuggestionsManager: ObservableObject {
    @Published var suggestions: [ServiceSuggestion] = []
    private let cacheKey = "CachedServiceFavicons"
    private var imageCache: [String: NSImage] = [:]

    // Popular streaming services
    private let defaultServices = KnownService.all.map { ServiceSuggestion(name: $0.name, url: $0.url) }

    init() {
        loadSuggestions()
    }

    private func loadSuggestions() {
        let cachedFavicons = loadCache()

        // Show all tiles immediately: cached favicons render right away, the rest
        // start in a loading state so the grid never appears empty or shifts later.
        suggestions = defaultServices.map { service in
            var updatedService = service
            updatedService.faviconData = cachedFavicons[service.url]
            updatedService.isLoadingFavicon = updatedService.faviconData == nil
            return updatedService
        }

        refreshFavicons()
    }

    /// Fetches the icons of all services. Missing icons appear when they arrive; cached
    /// icons stay on screen and are replaced, so a wrong or old icon in the cache does
    /// not stay forever.
    private func refreshFavicons() {
        // Fetch concurrently and publish each result as it arrives, so a single
        // slow host cannot hold up every other icon.
        for suggestion in suggestions {
            Task { [weak self] in
                let data = await Self.fetchFavicon(for: suggestion)
                self?.apply(data: data, for: suggestion.url)
            }
        }
    }

    /// Some sites send a "browser not supported" page or a consent page to unknown
    /// clients, with a different icon. A Safari user agent gets the real page.
    private static let browserHeaders: [String: String?] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    ]

    nonisolated static func fetchFavicon(for suggestion: ServiceSuggestion) async -> Data? {
        guard let url = URL(string: suggestion.url) else { return nil }
        do {
            let favicon = try await FaviconFinder(
                url: url,
                configuration: .init(checkForMetaRefreshRedirect: true, httpHeaders: browserHeaders)
            )
            .fetchFaviconURLs()
            .download()
            .largest()
            #if DEBUG
            print("Favicon for \(suggestion.name): \(favicon.url.source.absoluteString.prefix(100))")
            #endif
            return favicon.image?.data
        } catch {
            print("Failed to fetch favicon for \(suggestion.name): \(error)")
            return nil
        }
    }

    private func apply(data: Data?, for url: String) {
        guard let index = suggestions.firstIndex(where: { $0.url == url }) else { return }
        suggestions[index].isLoadingFavicon = false
        // Keep the cached icon when the fetch failed or returned the same icon.
        guard let data, data != suggestions[index].faviconData else { return }
        suggestions[index].faviconData = data
        imageCache[url] = nil
        cacheFaviconData(url: url, data: data)
    }

    private func loadCache() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private func cacheFaviconData(url: String, data: Data) {
        var cachedFavicons = loadCache()
        cachedFavicons[url] = data

        if let encodedData = try? JSONEncoder().encode(cachedFavicons) {
            UserDefaults.standard.set(encodedData, forKey: cacheKey)
        }
    }

    func getFaviconImage(for suggestion: ServiceSuggestion) -> NSImage? {
        guard let data = suggestion.faviconData else { return nil }
        if let cached = imageCache[suggestion.url] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        imageCache[suggestion.url] = image
        return image
    }
}
