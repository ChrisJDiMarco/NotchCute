// NotchCute: hover the MacBook notch, pick a cute category, watch cute things.
import AppKit
import SwiftUI
import AVFoundation
import CoreImage
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Categories

struct CuteCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let subreddits: [String]
}

let categories: [CuteCategory] = [
    CuteCategory(id: "bleach", name: "Eye Bleach", emoji: "✨", subreddits: ["Eyebleach", "aww"]),
    CuteCategory(id: "puppies", name: "Puppies", emoji: "🐶", subreddits: ["rarepuppers", "puppies", "corgi"]),
    CuteCategory(id: "cats", name: "Kitties", emoji: "🐱", subreddits: ["IllegallySmolCats", "kittens", "cats"]),
    CuteCategory(id: "tiny", name: "Tiny Critters", emoji: "🐹", subreddits: ["hamsters", "Rabbits", "sloths"]),
    CuteCategory(id: "birds", name: "Birbs", emoji: "🐦", subreddits: ["birbs", "partyparrot"]),
    CuteCategory(id: "wild", name: "Otters & Pals", emoji: "🦦", subreddits: ["Otters", "redpandas", "babyelephantgifs"]),
]

/// Baby animals on purpose: in Nittono et al., babies helped and adult animals barely did.
let boostCategory = CuteCategory(id: "boost", name: "Focus Boost", emoji: "🎯", subreddits: ["kittens", "puppies", "Eyebleach"])
let favoritesCategory = CuteCategory(id: "favorites", name: "Favorites", emoji: "❤️", subreddits: [])

let userAgent = "macos:com.chrisdimarco.notchcute:v0.2 (open source; github.com/ChrisJDiMarco/NotchCute)"
/// One pink, two springs, one radius family: every view draws from here so the app moves and looks like one thing.
enum Theme {
    static let pink = Color(red: 1.0, green: 0.62, blue: 0.72)
    static let pinkDeep = Color(red: 0.98, green: 0.45, blue: 0.55)
    /// Unfolding and arriving: quick, with a touch of overshoot.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// Tucking away: no bounce.
    static let settle = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let fade = Animation.easeInOut(duration: 0.45)
    static let cardRadius: CGFloat = 18
    static let playerRadius: CGFloat = 26
    /// How long the pointer rests in the notch before the panel opens.
    static let dwell: TimeInterval = 0.32
    /// The longer hover needed while a full-screen app is in front, so a presentation never gets surprise kittens.
    static let deliberateDwell: TimeInterval = 1.1
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern = .generic) {
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
    }
}

let supportDir: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchCute", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

enum Prefs {
    static let boostChoices: [Double] = [30, 60, 120]
    static var boostSeconds: Double {
        get { let v = UserDefaults.standard.double(forKey: "boostSeconds"); return v > 0 ? v : 60 }
        set { UserDefaults.standard.set(newValue, forKey: "boostSeconds") }
    }
    static func label(_ s: Double) -> String { s < 60 ? "\(Int(s)) s" : "\(Int(s / 60)) min" }
    static var breakReminders: Bool {
        get { UserDefaults.standard.bool(forKey: "breakReminders") }
        set { UserDefaults.standard.set(newValue, forKey: "breakReminders") }
    }
}

// MARK: - Feed

struct CuteItem: Hashable, Codable {
    let title: String
    let url: URL
    let isVideo: Bool
    let subreddit: String
    var permalink: URL? = nil
    var author: String? = nil
    var thumb: URL? = nil
}

func fetchData(_ url: URL) async throws -> Data {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
}

/// One feed request. Also reports how long Reddit wants us to wait before the next one.
func fetchFeed(_ url: URL) async -> (data: Data?, backoff: TimeInterval?) {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    guard let r = try? await URLSession.shared.data(for: req), let http = r.1 as? HTTPURLResponse else { return (nil, nil) }
    let header = { (k: String) in http.value(forHTTPHeaderField: k).flatMap(Double.init) }
    var backoff: TimeInterval? = nil
    if http.statusCode == 429 { backoff = header("Retry-After") ?? header("x-ratelimit-reset") ?? 60 }
    else if let left = header("x-ratelimit-remaining"), left < 1 { backoff = header("x-ratelimit-reset") ?? 60 }
    return (http.statusCode == 200 ? r.0 : nil, backoff)
}

final class AtomParser: NSObject, XMLParserDelegate {
    struct Entry { var title = "", content = "", link = "", sub = "", author = "", thumb = "" }
    var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "entry" { current = Entry() }
        else if current != nil {
            switch elementName {
            case "link": current!.link = attributeDict["href"] ?? ""
            case "category": current!.sub = attributeDict["term"] ?? ""
            case "media:thumbnail": current!.thumb = attributeDict["url"] ?? ""
            default: break
            }
        }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if current != nil {
            if elementName == "title" { current!.title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else if elementName == "content" { current!.content = text }
            else if elementName == "name" { current!.author = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/u/", with: "") }
            else if elementName == "entry" { entries.append(current!); current = nil }
        }
        text = ""
    }
}

let sadWords = ["rip ", "r.i.p", "passed away", "rainbow bridge", "put down", "euthan", "nsfw", "nsfl", "cancer", "died", "in memory"]

func mediaItem(_ e: AtomParser.Entry) -> CuteItem? {
    let lower = e.title.lowercased() + " "
    if sadWords.contains(where: { lower.contains($0) }) { return nil }
    guard let r = e.content.range(of: #"href="([^"]+)">\[link\]"#, options: .regularExpression) else { return nil }
    let raw = String(e.content[r])
        .replacingOccurrences(of: "href=\"", with: "")
        .replacingOccurrences(of: "\">[link]", with: "")
        .replacingOccurrences(of: "&amp;", with: "&")
    guard let u = URL(string: raw), let host = u.host?.lowercased() else { return nil }
    let thumb = URL(string: e.thumb)
    func item(_ url: URL, video: Bool) -> CuteItem {
        CuteItem(title: e.title, url: url, isVideo: video, subreddit: e.sub, permalink: URL(string: e.link), author: e.author.isEmpty ? nil : e.author, thumb: thumb)
    }
    let ext = u.pathExtension.lowercased()
    if host == "v.redd.it" { return item(u.appendingPathComponent("HLSPlaylist.m3u8"), video: true) }
    if host.hasSuffix("imgur.com") && (ext == "gifv" || ext == "mp4") {
        return item(u.deletingPathExtension().appendingPathExtension("mp4"), video: true)
    }
    // Galleries link to reddit.com, but the entry's preview thumbnail names the first image, which i.redd.it serves full size.
    if u.path.hasPrefix("/gallery/"), let t = thumb, t.host == "preview.redd.it", let full = URL(string: "https://i.redd.it/\(t.lastPathComponent)") {
        return item(full, video: false)
    }
    if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) { return item(u, video: false) }
    return nil
}

func parseFeed(_ data: Data) -> [CuteItem] {
    let p = AtomParser()
    let x = XMLParser(data: data)
    x.delegate = p
    x.parse()
    return p.entries.compactMap(mediaItem)
}

/// One combined request per category, spaced at least 2.5 s apart and held back for as long as
/// Reddit's rate-limit headers ask (often a full minute). The last good copy lives on disk.
actor FeedStore {
    static let shared = FeedStore()
    static let freshFor: TimeInterval = 900
    private var memory: [String: (Date, [CuteItem])] = [:]
    private var nextSlot = Date.distantPast
    private var waitUntil = Date.distantPast
    private var foregroundWaiting = 0
    private let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchCute", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(_ c: CuteCategory) -> URL { cacheDir.appendingPathComponent("feed-\(c.id).xml") }

    /// Whatever is already in memory or on disk, without touching the network.
    func cached(_ c: CuteCategory) -> (items: [CuteItem], age: TimeInterval) {
        if let m = memory[c.id] { return (m.1, Date().timeIntervalSince(m.0)) }
        let f = file(c)
        guard let d = try? Data(contentsOf: f) else { return ([], .infinity) }
        let saved = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let items = parseFeed(d)
        if !items.isEmpty { memory[c.id] = (saved, items) }
        return (items, Date().timeIntervalSince(saved))
    }

    func secondsUntilAllowed() -> TimeInterval { max(0, max(nextSlot, waitUntil).timeIntervalSinceNow) }

    /// Fetches the category's combined feed. Background refreshes give up instead of waiting
    /// and never take a turn someone looking at the screen is waiting for.
    func refresh(_ c: CuteCategory, background: Bool = false) async -> [CuteItem]? {
        let subs = c.subreddits.joined(separator: "+")
        guard !subs.isEmpty, let url = URL(string: "https://www.reddit.com/r/\(subs)/hot/.rss?limit=100") else { return nil }
        if background && (foregroundWaiting > 0 || secondsUntilAllowed() > 0) { return nil }
        if !background { foregroundWaiting += 1 }
        while secondsUntilAllowed() > 0 {
            if Task.isCancelled { foregroundWaiting -= 1; return nil }
            try? await Task.sleep(for: .seconds(secondsUntilAllowed()))
        }
        if !background { foregroundWaiting -= 1 }
        if Task.isCancelled { return nil }
        nextSlot = Date().addingTimeInterval(2.5)
        let (data, backoff) = await fetchFeed(url)
        if let b = backoff { waitUntil = Date().addingTimeInterval(b + 1) }
        guard let data else { return nil }
        let items = parseFeed(data)
        guard !items.isEmpty else { return nil }
        try? data.write(to: file(c), options: .atomic)
        memory[c.id] = (Date(), items)
        return items
    }
}

// MARK: - Local stores

@MainActor final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    init() { cache.countLimit = 60 }

    func image(_ url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let t = inflight[url] { return await t.value }
        let t = Task<NSImage?, Never> { (try? await fetchData(url)).flatMap(NSImage.init(data:)) }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func prefetch(_ url: URL) { Task { _ = await image(url) } }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
}

@MainActor final class Favorites: ObservableObject {
    static let shared = Favorites()
    @Published private(set) var items: [CuteItem]
    private let file = supportDir.appendingPathComponent("favorites.json")

    init() { items = (try? JSONDecoder().decode([CuteItem].self, from: Data(contentsOf: file))) ?? [] }

    func contains(_ i: CuteItem) -> Bool { items.contains { $0.url == i.url } }

    func toggle(_ i: CuteItem) {
        if let k = items.firstIndex(where: { $0.url == i.url }) { items.remove(at: k) } else { items.insert(i, at: 0) }
        try? JSONEncoder().encode(items).write(to: file, options: .atomic)
    }
}

/// Remembers what you've already watched so each visit leads with posts you haven't seen.
@MainActor enum Seen {
    private static var order = UserDefaults.standard.stringArray(forKey: "seen") ?? []
    private static var set = Set(order)

    static func contains(_ u: URL) -> Bool { set.contains(u.absoluteString) }

    static func mark(_ u: URL) {
        let k = u.absoluteString
        guard set.insert(k).inserted else { return }
        order.append(k)
        if order.count > 3000 { set.subtract(order.prefix(500)); order.removeFirst(500) }
        UserDefaults.standard.set(order, forKey: "seen")
    }
}

// MARK: - Player model

@MainActor final class PlayerModel: ObservableObject {
    enum LoadState: Equatable { case loading, waiting(until: Date), empty(String) }
    static let imageSeconds: TimeInterval = 8

    let category: CuteCategory
    let boostLength: TimeInterval?
    @Published private(set) var items: [CuteItem] = []
    @Published private(set) var index = 0
    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var paused = false
    @Published var muted = true
    @Published private(set) var boostLeft: TimeInterval = 0
    @Published private(set) var boostDone = false
    @Published private(set) var hearts = 0
    @Published private(set) var toast: String?
    var videoProgress: Double = 0
    var onBoostDone: (() -> Void)?
    var onBoostTick: ((TimeInterval) -> Void)?
    var onTint: ((Color) -> Void)?

    private var startedItem: CuteItem?
    private var everStarted = false
    private var deadline: Date?
    private var remaining: TimeInterval?
    private var advanceTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var boostTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private let lead: CuteItem?

    /// `lead` is the post a card was showing; the player opens on it.
    init(category: CuteCategory, boostLength: TimeInterval? = nil, lead: CuteItem? = nil) {
        self.category = category
        self.boostLength = boostLength
        self.lead = lead
        self.boostLeft = boostLength ?? 0
    }

    var current: CuteItem? { items.indices.contains(index) ? items[index] : nil }

    func load() {
        startBoost()
        if let lead { merge([lead]) }
        if category.id == favoritesCategory.id {
            merge(Favorites.shared.items)
            if items.isEmpty { loadState = .empty("No favorites yet. Press F or ♥ on anything you love.") }
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let cached = await FeedStore.shared.cached(self.category)
            self.merge(cached.items)
            guard cached.age > FeedStore.freshFor else { return }
            if self.items.isEmpty {
                let wait = await FeedStore.shared.secondsUntilAllowed()
                if wait > 3 { self.loadState = .waiting(until: Date().addingTimeInterval(wait)) }
            }
            let fresh = await FeedStore.shared.refresh(self.category)
            if Task.isCancelled { return }
            if let fresh { self.merge(fresh) }
            if self.items.isEmpty { self.loadState = .empty("Reddit didn't send anything just now. Try again in a minute.") }
        }
    }

    /// Unseen posts go first, in random order, ahead of anything you've watched before.
    private func merge(_ new: [CuteItem]) {
        var known = Set(items.map(\.url))
        let fresh = new.filter { known.insert($0.url).inserted }
        let unseen = fresh.filter { !Seen.contains($0.url) }.shuffled()
        let seen = fresh.filter { Seen.contains($0.url) }.shuffled()
        if items.isEmpty {
            items = unseen + seen
            index = 0
            if current != nil { didChangeCurrent() }
            return
        }
        var boundary = items.indices.dropFirst(index + 1).first { Seen.contains(items[$0].url) } ?? items.count
        for it in unseen {
            items.insert(it, at: Int.random(in: (index + 1)...boundary))
            boundary += 1
        }
        items.append(contentsOf: seen)
    }

    func next() {
        guard !items.isEmpty, !boostDone else { return }
        index = (index + 1) % items.count
        didChangeCurrent()
    }

    func prev() {
        guard !items.isEmpty, !boostDone else { return }
        index = (index - 1 + items.count) % items.count
        didChangeCurrent()
    }

    /// The clock for an item starts when it's actually on screen, not when it was requested.
    private func didChangeCurrent() {
        advanceTask?.cancel()
        watchdogTask?.cancel()
        deadline = nil
        remaining = nil
        startedItem = nil
        videoProgress = 0
        guard let item = current else { return }
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.current == item, self.startedItem != item else { return }
            self.failed(item)
        }
        if items.count > 1 {
            let n = items[(index + 1) % items.count]
            if !n.isVideo { ImageCache.shared.prefetch(n.url) }
        }
    }

    func ready(_ item: CuteItem) {
        guard current == item, startedItem != item else { return }
        startedItem = item
        everStarted = true
        watchdogTask?.cancel()
        Seen.mark(item.url)
        // Videos advance when they end; the long cap only covers a stream that never reports it.
        startAdvance(after: item.isVideo ? 300 : Self.imageSeconds)
    }

    func ended(_ item: CuteItem) { if current == item { next() } }

    func failed(_ item: CuteItem) {
        guard let i = items.firstIndex(of: item) else { return }
        let wasCurrent = i == index
        items.remove(at: i)
        if items.isEmpty { index = 0; loadState = .empty("Couldn't load anything from this category right now."); didChangeCurrent(); return }
        if i < index { index -= 1 }
        else if wasCurrent { if index >= items.count { index = 0 }; didChangeCurrent() }
    }

    func tint(_ c: Color, for item: CuteItem) { if current == item { onTint?(c) } }

    func videoProgressed(_ f: Double, for item: CuteItem) { if current == item { videoProgress = f } }

    /// How far through the current post we are, for the story bar.
    func progress(at now: Date) -> Double {
        guard let item = current, startedItem == item else { return 0 }
        if item.isVideo { return videoProgress }
        if let d = deadline { return 1 - max(0, d.timeIntervalSince(now)) / Self.imageSeconds }
        if let r = remaining { return 1 - r / Self.imageSeconds }
        return 0
    }

    func toggleFavorite() {
        guard let item = current else { return }
        Favorites.shared.toggle(item)
        if Favorites.shared.contains(item) { hearts += 1; Theme.haptic() }
    }

    /// ⌘C: the picture itself for stills, the post's link for videos.
    func copyCurrent() {
        guard let item = current else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !item.isVideo, let img = ImageCache.shared.cached(item.url) {
            pb.writeObjects([img])
            showToast("Image copied")
        } else {
            pb.setString((item.permalink ?? item.url).absoluteString, forType: .string)
            showToast("Link copied")
        }
    }

    /// What the share menu sends: the picture when there is one, plus a link back to the post.
    func shareItems() -> [Any] {
        guard let item = current else { return [] }
        var out: [Any] = []
        if !item.isVideo, let img = ImageCache.shared.cached(item.url) { out.append(img) }
        out.append(item.permalink ?? item.url)
        return out
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.toast = nil }
        }
    }

    private func startAdvance(after secs: TimeInterval) {
        advanceTask?.cancel()
        if paused { remaining = secs; deadline = nil; return }
        deadline = Date().addingTimeInterval(secs)
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            if Task.isCancelled { return }
            self?.next()
        }
    }

    func togglePause() {
        guard !boostDone else { return }
        paused.toggle()
        if paused {
            if let d = deadline { remaining = max(0.5, d.timeIntervalSinceNow) }
            advanceTask?.cancel()
            deadline = nil
        } else if let r = remaining {
            remaining = nil
            startAdvance(after: r)
        }
    }

    private func startBoost() {
        guard boostLength != nil else { return }
        onBoostTick?(boostLeft)
        boostTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if self.paused || !self.everStarted { continue }
                self.boostLeft = max(0, self.boostLeft - 0.1)
                self.onBoostTick?(self.boostLeft)
                if self.boostLeft == 0 { self.finishBoost(); return }
            }
        }
    }

    private func finishBoost() {
        advanceTask?.cancel()
        watchdogTask?.cancel()
        Theme.haptic(.levelChange)
        withAnimation(.easeOut(duration: 0.35)) { boostDone = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            self?.onBoostDone?()
        }
    }

    func stop() { advanceTask?.cancel(); watchdogTask?.cancel(); loadTask?.cancel(); boostTask?.cancel(); toastTask?.cancel() }
}

// MARK: - Media

extension NSImage {
    /// The picture's average color, lifted a little so it reads as a glow rather than mud.
    var glowColor: Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]) }
        let total = Double(n * n) * 255
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Color(hue: h, saturation: min(1, s * 1.35 + 0.08), brightness: min(0.95, max(0.5, v * 1.25)))
    }
}

/// NSImageView, only for GIFs, so they animate.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.image = image
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) { if v.image !== image { v.image = image } }
}

final class PlayerNSView: NSView {
    private static let ci = CIContext()
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let seamLayer = CALayer()
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var timeObserver: Any?
    private var startedAt: Date?
    private var paused: Bool
    private let onReady: () -> Void
    private let onEnd: () -> Void
    private let onFail: () -> Void
    private let onProgress: (Double) -> Void

    init(url: URL, paused: Bool, muted: Bool, onReady: @escaping () -> Void, onEnd: @escaping () -> Void,
         onFail: @escaping () -> Void, onProgress: @escaping (Double) -> Void) {
        self.paused = paused
        self.onReady = onReady
        self.onEnd = onEnd
        self.onFail = onFail
        self.onProgress = onProgress
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        seamLayer.contentsGravity = .resizeAspect
        seamLayer.opacity = 0
        layer?.addSublayer(seamLayer)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        player.isMuted = muted
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let s = it.status
            Task { @MainActor in
                if s == .failed { self?.onFail() }
                else if s == .readyToPlay, let self, self.startedAt == nil { self.startedAt = Date(); self.onReady() }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.onProgress(min(1, t.seconds / d))
            }
        }
        if !paused { player.play() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Short clips loop until they've had 8 s on screen, so a 3 s GIF doesn't flash by.
    /// Each loop crossfades out of the clip's last frame instead of jumping back to the start.
    private func reachedEnd() {
        guard let s = startedAt, Date().timeIntervalSince(s) < PlayerModel.imageSeconds else { onEnd(); return }
        holdLastFrame()
        player.seek(to: .zero)
        if !paused { player.play() }
    }

    private func holdLastFrame() {
        guard let buf = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else { return }
        let img = CIImage(cvPixelBuffer: buf)
        guard let cg = Self.ci.createCGImage(img, from: img.extent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        seamLayer.contents = cg
        seamLayer.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        seamLayer.add(fade, forKey: "seam")
    }

    func apply(paused: Bool, muted: Bool) {
        player.isMuted = muted
        guard paused != self.paused else { return }
        self.paused = paused
        if paused { player.pause() } else { player.play() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        seamLayer.frame = bounds
        CATransaction.commit()
    }

    func teardown() {
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t) }
        player.replaceCurrentItem(with: nil)
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        statusObs = nil
    }
}

struct VideoMedia: NSViewRepresentable {
    let url: URL
    let paused: Bool
    let muted: Bool
    let onReady: () -> Void
    let onEnd: () -> Void
    let onFail: () -> Void
    let onProgress: (Double) -> Void
    func makeNSView(context: Context) -> PlayerNSView {
        PlayerNSView(url: url, paused: paused, muted: muted, onReady: onReady, onEnd: onEnd, onFail: onFail, onProgress: onProgress)
    }
    func updateNSView(_ nsView: PlayerNSView, context: Context) { nsView.apply(paused: paused, muted: muted) }
    static func dismantleNSView(_ nsView: PlayerNSView, coordinator: ()) { nsView.teardown() }
}

/// One post, full bleed: the media over a blurred copy of itself, so nothing letterboxes onto black.
/// The post's thumbnail shows at once, sharp, and the real media fades in over it. Stills drift in slowly.
struct MediaView: View {
    let item: CuteItem
    @ObservedObject var model: PlayerModel
    @State private var image: NSImage?
    @State private var poster: NSImage?
    @State private var videoReady = false
    @State private var zoomed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // In an overlay so the fill-scaled image can't make the layout wider than the card.
            Color.clear.overlay {
                if let b = image ?? poster {
                    Image(nsImage: b).resizable().scaledToFill()
                        .blur(radius: 40, opaque: true)
                        .overlay(Color.black.opacity(0.35))
                        .transition(.opacity)
                }
            }
            .clipped()
            if item.isVideo {
                VideoMedia(url: item.url, paused: model.paused || model.boostDone, muted: model.muted,
                           onReady: { videoReady = true; model.ready(item) }, onEnd: { model.ended(item) }, onFail: { model.failed(item) },
                           onProgress: { model.videoProgressed($0, for: item) })
                if !videoReady, let poster { still(poster).transition(.opacity) }
            } else if let image {
                Group {
                    if item.url.pathExtension.lowercased() == "gif" { AnimatedImage(image: image) } else { still(image) }
                }
                .scaleEffect(zoomed ? 1.06 : 1)
                .transition(.opacity)
            } else if let poster {
                still(poster).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: videoReady)
        .animation(.easeOut(duration: 0.35), value: image != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(.isImage)
        .task { await load() }
    }

    private func still(_ img: NSImage) -> some View {
        Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
    }

    private func load() async {
        if let t = item.thumb { poster = ImageCache.shared.cached(t) }
        if let p = poster { await applyTint(p) }
        if item.isVideo {
            guard poster == nil, let t = item.thumb, let img = await ImageCache.shared.image(t) else { return }
            poster = img
            await applyTint(img)
            return
        }
        guard let img = await ImageCache.shared.image(item.url) else { model.failed(item); return }
        image = img
        model.ready(item)
        if !reduceMotion { withAnimation(.linear(duration: PlayerModel.imageSeconds + 1)) { zoomed = true } }
        if poster == nil { await applyTint(img) }
    }

    private func applyTint(_ img: NSImage) async {
        if let c = await Task.detached(priority: .utility, operation: { img.glowColor }).value { model.tint(c, for: item) }
    }
}


// MARK: - Spotlight

/// Wraps an overlay card: dims and tints the screen, and flies the card out of `origin` (a notch card,
/// or the notch itself) to the center, then back into the notch on close.
@MainActor final class OverlayState: ObservableObject {
    @Published var presented = false
    @Published var origin: CGRect
    @Published private(set) var tint: Color?
    @Published private(set) var tintKey = 0
    init(origin: CGRect) { self.origin = origin }
    func setTint(_ c: Color) { tint = c; tintKey += 1 }
}

struct Presented<Content: View>: View {
    @ObservedObject var overlay: OverlayState
    let cardSize: CGSize
    let close: () -> Void
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { g in
            let p = overlay.presented
            let o = overlay.origin
            let s = reduceMotion ? 1 : max(0.04, o.width / cardSize.width)
            let dx = reduceMotion ? 0 : o.midX - g.size.width / 2
            let dy = reduceMotion ? 0 : o.midY - g.size.height / 2
            ZStack {
                backdrop(g.size)
                    .opacity(p ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                content
                    .opacity(p ? 1 : 0)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .background(Color(white: 0.07))
                    .clipShape(RoundedRectangle(cornerRadius: p ? Theme.playerRadius : min(Theme.cardRadius / s, cardSize.height / 2), style: .continuous))
                    .shadow(color: .black.opacity(p ? 0.5 : 0), radius: 40, y: 14)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .scaleEffect(p ? 1 : s)
                    .offset(x: p ? 0 : dx, y: p ? 0 : dy)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private func backdrop(_ size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.94 : 0.8)
            if let t = overlay.tint {
                RadialGradient(colors: [t.opacity(0.6), t.opacity(0.28), .clear], center: .center,
                               startRadius: min(size.width, size.height) * 0.25, endRadius: max(size.width, size.height) * 0.7)
                    .id(overlay.tintKey)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.1), value: overlay.tintKey)
    }
}

/// Mouse movement over the card, kept outside SwiftUI state so it doesn't redraw on every move.
final class Activity { var last = Date() }

struct SpotlightView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var favorites = Favorites.shared
    let close: () -> Void
    let open: (URL) -> Void
    let onShare: () -> Void
    @State private var chrome = true
    @State private var activity = Activity()
    @State private var overControls = false

    /// Title, credit and controls step back after a couple of quiet seconds and return on any mouse move.
    private var chromeShown: Bool { chrome || overControls || model.paused || model.current == nil || model.boostDone }

    var body: some View {
        ZStack {
            ZStack {
                if let item = model.current {
                    MediaView(item: item, model: model).id(item.url).transition(.opacity)
                } else {
                    placeholder.transition(.opacity)
                }
            }
            .animation(Theme.fade, value: model.current?.url)
            scrims
            chromeLayer
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .modifier(GlassCapsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
            if model.boostDone { doneOverlay.transition(.opacity) }
        }
        .foregroundColor(.white)
        .onContinuousHover { phase in if case .active = phase { poke() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                if chrome && Date().timeIntervalSince(activity.last) > 2.2 { withAnimation(.easeOut(duration: 0.5)) { chrome = false } }
            }
        }
    }

    private func poke() {
        activity.last = Date()
        if !chrome { withAnimation(.easeOut(duration: 0.2)) { chrome = true } }
    }

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .opacity(chromeShown || model.boostLength != nil ? 1 : 0)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .frame(height: 190)
                .opacity(chromeShown ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    private var chromeLayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                progressRow.opacity(chromeShown || model.boostLength != nil ? 1 : 0)
                HStack(spacing: 8) {
                    Text("\(model.category.emoji)  \(model.category.name)").font(.system(size: 13, weight: .semibold, design: .rounded))
                    if let s = model.current?.subreddit, !s.isEmpty {
                        Text("r/\(s)").font(.system(size: 13, design: .rounded)).opacity(0.6)
                    }
                    Spacer()
                    CloseButton(action: close)
                }
                .opacity(chromeShown ? 1 : 0)
                .allowsHitTesting(chromeShown)
            }
            Spacer(minLength: 0)
            bottomRow
                .opacity(chromeShown ? 1 : 0)
                .allowsHitTesting(chromeShown)
        }
        .padding(18)
    }

    @ViewBuilder private var progressRow: some View {
        if let len = model.boostLength {
            HStack(spacing: 10) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(Theme.pink).frame(width: g.size.width * (1 - model.boostLeft / len)) }
                    }
                    .animation(.linear(duration: 0.1), value: model.boostLeft)
                Text(clock(model.boostLeft)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().opacity(0.85)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Focus Boost, \(Int(model.boostLeft.rounded(.up))) seconds left")
        } else {
            StorySegments(model: model, paused: !chromeShown)
                .accessibilityHidden(true)
        }
    }

    private var bottomRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if let item = model.current {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 8)
                    if item.permalink != nil {
                        HStack(spacing: 6) {
                            if let a = item.author {
                                Text("u/\(a)").opacity(0.65)
                                Text("·").opacity(0.4)
                            }
                            Text("Open on Reddit ›").foregroundColor(Theme.pink)
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let p = item.permalink { open(p) } }
                .help(item.permalink == nil ? "" : "Open this post on Reddit (O)")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(item.permalink == nil ? [] : .isLink)
            }
            Spacer(minLength: 12)
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if let item = model.current {
                let fav = favorites.contains(item)
                PillButton(symbol: fav ? "heart.fill" : "heart", tint: fav ? Theme.pink : .white,
                           label: fav ? "Remove from favorites" : "Favorite", shortcut: "F", bounce: model.hearts) {
                    model.toggleFavorite()
                }
                .overlay { if model.hearts > 0 { HeartBurst().id(model.hearts) } }
                if item.isVideo {
                    PillButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                               label: model.muted ? "Turn sound on" : "Mute", shortcut: "M") { model.muted.toggle() }
                }
                ShareControl(items: { model.shareItems() }, onChoose: onShare)
            }
            PillButton(symbol: model.paused ? "play.fill" : "pause.fill", label: model.paused ? "Resume" : "Pause", shortcut: "Space") {
                model.togglePause()
            }
            PillButton(symbol: "chevron.left", label: "Previous", shortcut: "←") { model.prev() }
            PillButton(symbol: "chevron.right", label: "Next", shortcut: "→") { model.next() }
        }
        .padding(4)
        .modifier(GlassCapsule())
        .onHover { overControls = $0 }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 14) {
            switch model.loadState {
            case .loading:
                PawPulse()
                Text("Fetching cute things…")
            case .waiting(let until):
                SleepyCat()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Reddit asked for a short break. Back in \(max(1, Int(until.timeIntervalSince(ctx.date).rounded(.up)))) s")
                }
            case .empty(let message):
                Text("🙀").font(.system(size: 44))
                Text(message)
            }
        }
        .font(.system(size: 14, design: .rounded))
        .foregroundColor(.white.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneOverlay: some View {
        VStack(spacing: 8) {
            Text("✨").font(.system(size: 52))
            Text("That's your boost.").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Now go do the careful stuff.").font(.system(size: 15, design: .rounded)).opacity(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.62))
        .accessibilityElement(children: .combine)
    }
}


/// A short window of story-style segments around the current post; the current one fills as it plays.
struct StorySegments: View {
    @ObservedObject var model: PlayerModel
    let paused: Bool

    var body: some View {
        let n = model.items.count
        let i = model.index
        let span = min(n, 7)
        let start = n <= 7 ? 0 : min(max(0, i - 2), n - span)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { ctx in
            HStack(spacing: 4) {
                ForEach(0..<span, id: \.self) { k in
                    let idx = start + k
                    let f: Double = idx < i ? 1 : idx > i ? 0 : model.progress(at: ctx.date)
                    Capsule().fill(Color.white.opacity(0.28))
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(Color.white).frame(width: g.size.width * f) }
                        }
                }
            }
        }
        .frame(height: 3)
    }
}

struct PillButton: View {
    let symbol: String
    var tint: Color = .white
    let label: String
    var shortcut: String? = nil
    var bounce = 0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(hover ? 0.24 : 0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

/// The system share menu (Messages, AirDrop, Mail…), anchored to a real AppKit button so it can pop up from the pill.
final class ShareNSButton: NSButton, NSSharingServicePickerDelegate {
    var items: () -> [Any] = { [] }
    var onChoose: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = .white
        target = self
        action = #selector(share)
        setAccessibilityLabel("Share")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func share() {
        let picker = NSSharingServicePicker(items: items())
        picker.delegate = self
        picker.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service != nil { onChoose() }
    }
}

struct ShareButton: NSViewRepresentable {
    let items: () -> [Any]
    let onChoose: () -> Void
    func makeNSView(context: Context) -> ShareNSButton { ShareNSButton(frame: .zero) }
    func updateNSView(_ b: ShareNSButton, context: Context) {
        b.items = items
        b.onChoose = onChoose
    }
}

struct ShareControl: View {
    let items: () -> [Any]
    let onChoose: () -> Void
    @State private var hover = false

    var body: some View {
        ShareButton(items: items, onChoose: onChoose)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0)))
            .onHover { hover = $0 }
            .help("Share (⌘C copies)")
    }
}


struct GlassCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { Capsule().fill(Color.black.opacity(0.85)) } else { Capsule().fill(.ultraThinMaterial) }
        }
    }
}

struct HeartBurst: View {
    @State private var fly = false

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let a = Double(i) / 7 * 2 * .pi - .pi / 2
                Image(systemName: "heart.fill")
                    .font(.system(size: 8 + CGFloat(i % 3) * 2))
                    .foregroundColor(Theme.pink)
                    .offset(x: fly ? cos(a) * 30 : 0, y: fly ? sin(a) * 30 : 0)
                    .scaleEffect(fly ? 0.5 : 1)
                    .opacity(fly ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.65)) { fly = true } }
    }
}

struct PawPulse: View {
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("🐾").font(.system(size: 40))
            .scaleEffect(up ? 1.1 : 0.92)
            .opacity(up ? 1 : 0.6)
            .onAppear {
                guard !reduceMotion else { up = true; return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

struct SleepyCat: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate / 2.4
            ZStack(alignment: .topTrailing) {
                Text("🐱").font(.system(size: 52))
                ForEach(0..<3, id: \.self) { i in
                    let f = (t + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("z")
                        .font(.system(size: 11 + CGFloat(i) * 3, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8 * (1 - f)))
                        .offset(x: 6 + f * 18, y: -f * 34)
                }
            }
        }
    }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Research card

struct ResearchView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Why NotchCute exists").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                CloseButton(action: close)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("I came across a study from Hiroshima University showing that a short look at baby animals makes people more careful and more focused afterward. That seemed worth having one hover away, so I built this. Here is what the research found.")
                        .font(.system(size: 14, design: .rounded)).opacity(0.85)

                    heading("The Power of Kawaii", "Nittono, Fukushima, Yano & Moriya · Hiroshima University · PLoS ONE, 2012")
                    item("🩺  Steadier hands", "In an Operation-style tweezers game, people who first looked at puppy and kitten photos improved their scores by 43.9%. People shown adult dogs and cats improved by 11.9%. The baby-animal group slowed down and worked more carefully.")
                    item("🔍  Sharper eyes", "In a timed number-search task, the baby-animal group improved 15.7%. Adult animals: 1.4%. Photos of tasty food: 1.2%. So it isn't just feeling good. Cuteness itself did the work.")
                    item("🎯  Tighter focus", "Cute images made people less likely to see the big picture first and more likely to zero in on the details.")
                    item("🧠  Why it works", "Baby features like big eyes, round faces and large heads switch on a caretaking instinct. Instead of relaxing you, that instinct makes you careful.")

                    heading("Related research", "")
                    item("🐈  Cat videos and mood", "Myrick, 2015 · Computers in Human Behavior. A survey of nearly 7,000 people found that watching cat videos online left them feeling more energetic and positive, and less anxious, annoyed and sad. These were people's own reports of how they felt.")
                    item("🏀  Free throws under pressure", "Yoshikawa & Masaki, 2021 · Frontiers in Psychology. A smaller follow-up tested whether looking at cute pictures helps people keep their free-throw accuracy when the pressure is on.")

                    heading("When to use it", "")
                    Text("A quick look helps most before detail work: proofreading, checking numbers, careful editing. It helps less before brainstorming, because a narrower focus is the whole effect. That's what Focus Boost is for: a short run of baby animals that ends on its own and sends you back to work.")
                        .font(.system(size: 14, design: .rounded)).opacity(0.85)

                    heading("Read the papers", "")
                    VStack(alignment: .leading, spacing: 8) {
                        Link("Nittono et al. (2012), PLoS ONE ›", destination: URL(string: "https://doi.org/10.1371/journal.pone.0046362")!)
                        Link("Myrick (2015), Computers in Human Behavior ›", destination: URL(string: "https://doi.org/10.1016/j.chb.2015.06.001")!)
                        Link("Yoshikawa & Masaki (2021), Frontiers in Psychology ›", destination: URL(string: "https://doi.org/10.3389/fpsyg.2021.610817")!)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(Theme.pink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
            }
        }
        .foregroundColor(.white)
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(Theme.pink)
            if !sub.isEmpty { Text(sub).font(.system(size: 12, design: .rounded)).opacity(0.55) }
        }
        .padding(.top, 4)
    }

    private func item(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(body).font(.system(size: 13.5, design: .rounded)).opacity(0.8).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Notch gallery

/// hidden: tucked behind the notch. peek: you're hovering and it's about to open. nudge: an optional break
/// reminder, the eyes peeking out on their own. open: the gallery. glow: a Focus Boost landing back in the notch.
enum NotchPhase { case hidden, peek, nudge, open, glow }

@MainActor final class NotchState: ObservableObject {
    @Published var phase = NotchPhase.hidden
    @Published var thumbs: [String: NSImage] = [:]
    /// The post each card's thumbnail came from, so picking the card opens on that same post.
    var thumbItems: [String: CuteItem] = [:]
    @Published var favoriteStack: [NSImage] = []
    @Published var notchSize = CGSize(width: 180, height: 0)
    @Published var panelSize = CGSize(width: 700, height: 200)
    @Published var notchHeight: CGFloat = 32
    @Published var dwell = Theme.dwell
    /// Where the pointer sits across the notch, -1 (left) to 1 (right), for the eyes to follow.
    @Published var gaze: CGFloat = 0
    /// The card chosen with the keyboard.
    @Published var selected: String?
}

/// The panel's cards in order: Focus Boost, the categories, then Favorites once there are any.
@MainActor func panelCards() -> [CuteCategory] {
    [boostCategory] + categories + (Favorites.shared.items.isEmpty ? [] : [favoritesCategory])
}

let cardWidth: CGFloat = 96
let cardSpacing: CGFloat = 10

struct NotchGalleryView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var favorites = Favorites.shared
    let onPick: (CuteCategory, CGRect?) -> Void
    let onAbout: () -> Void
    @State private var hovered: String?
    @State private var aboutHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var open: Bool { state.phase == .open }

    /// One black shape that is the notch, grows a little while you hover, and unfolds into the gallery.
    var body: some View {
        let size = shapeSize
        let r: CGFloat = open ? 28 : 10
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        ZStack(alignment: .top) {
            content.frame(width: state.panelSize.width, height: state.panelSize.height, alignment: .top)
            if state.phase == .peek || state.phase == .nudge {
                PeekFace(dwell: state.dwell, nudge: state.phase == .nudge, gaze: state.gaze)
                    .id(state.phase == .nudge)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(shape)
        .background(shape.fill(Color.black).shadow(color: Theme.pink.opacity(state.phase == .glow ? 0.95 : 0), radius: state.phase == .glow ? 18 : 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var shapeSize: CGSize {
        let n = state.notchSize
        switch state.phase {
        case .open: return state.panelSize
        case .peek, .nudge: return CGSize(width: n.width + 28, height: n.height + 18)
        case .glow: return CGSize(width: n.width + 10, height: max(n.height, 6) + 4)
        case .hidden: return n
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: state.notchHeight)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    ForEach(Array(panelCards().enumerated()), id: \.element.id) { i, c in
                        card(c)
                            .opacity(open ? 1 : 0)
                            .offset(y: open || reduceMotion ? 0 : -14)
                            .scaleEffect(open || reduceMotion ? 1 : 0.9, anchor: .top)
                            .animation(open ? (reduceMotion ? .easeOut(duration: 0.15) : Theme.open.delay(0.05 + Double(i) * 0.035)) : .easeIn(duration: 0.1), value: open)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            HStack(spacing: 5) {
                Text("Research says a peek at baby animals sharpens your focus, so I put it one hover away.")
                    .foregroundColor(.white.opacity(0.72))
                Text("See why ›")
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.pink)
                    .underline(aboutHovered)
            }
            .font(.system(size: 12, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { aboutHovered = $0 }
            .onTapGesture { onAbout() }
            .padding(.bottom, 12)
            .opacity(open ? 1 : 0)
            .animation(open ? .easeOut(duration: 0.3).delay(0.25) : .easeIn(duration: 0.1), value: open)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    private func sub(for c: CuteCategory) -> String? {
        if c.id == boostCategory.id { return Prefs.label(Prefs.boostSeconds) }
        if c.id == favoritesCategory.id { return "\(favorites.items.count)" }
        return nil
    }

    private func card(_ c: CuteCategory) -> some View {
        let lit = hovered == c.id || state.selected == c.id
        let accent = c.id == boostCategory.id
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            if accent {
                LinearGradient(colors: [Theme.pink, Theme.pinkDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color.white.opacity(lit ? 0.2 : 0.08)
            }
            if c.id == favoritesCategory.id, !state.favoriteStack.isEmpty {
                FavoriteStack(images: state.favoriteStack, fanned: lit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -14)
                cornerLabel(c)
            } else if !accent, let t = state.thumbs[c.id] {
                Image(nsImage: t).resizable().scaledToFill().frame(width: cardWidth, height: 112).clipped()
                    .scaleEffect(lit ? 1.08 : 1)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                cornerLabel(c)
            } else {
                VStack(spacing: 5) {
                    Text(c.emoji).font(.system(size: 40))
                    Text(c.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                    if let sub = sub(for: c) { Text(sub).font(.system(size: 10, weight: .medium, design: .rounded)).opacity(0.75) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundColor(.white)
        .frame(width: cardWidth, height: 112)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(lit ? 0.55 : 0), lineWidth: 1.5))
        .overlay(GeometryReader { g in
            Color.clear.contentShape(Rectangle()).onTapGesture { onPick(c, g.frame(in: .global)) }
        })
        .scaleEffect(lit ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lit)
        .onHover { h in if h { hovered = c.id } else if hovered == c.id { hovered = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.name + (sub(for: c).map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPick(c, nil) }
    }

    private func cornerLabel(_ c: CuteCategory) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(c.emoji).font(.system(size: 18))
            HStack(spacing: 4) {
                Text(c.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                if c.id == favoritesCategory.id, let sub = sub(for: c) {
                    Text(sub).font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.7)
                }
            }
        }
        .padding(8)
    }
}

/// Up to three saved posts, fanned like photos on a table, the newest pick in front. They spread a little on hover.
struct FavoriteStack: View {
    let images: [NSImage]
    let fanned: Bool

    var body: some View {
        let n = min(images.count, 3)
        // Draw the sides first so the first image sits on top in the middle.
        let slots: [(image: Int, pos: Double)] = n == 3 ? [(1, -1), (2, 1), (0, 0)] : n == 2 ? [(1, -0.5), (0, 0.5)] : [(0, 0)]
        ZStack {
            ForEach(0..<slots.count, id: \.self) { k in
                let s = slots[k]
                Image(nsImage: images[s.image]).resizable().scaledToFill()
                    .frame(width: 46, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .rotationEffect(.degrees(s.pos * (fanned ? 13 : 8)))
                    .offset(x: s.pos * (fanned ? 17 : 11), y: abs(s.pos) * 3)
            }
        }
    }
}

/// Two eyes and a filling line under the notch while the pointer rests there: it noticed you, and it's opening.
/// The eyes follow the pointer. As a break reminder (`nudge`) they just peek out and blink, with no line.
struct PeekFace: View {
    let dwell: TimeInterval
    let nudge: Bool
    let gaze: CGFloat
    @State private var shown = false
    @State private var blink = false
    @State private var fill = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            HStack(spacing: 14) { eye; eye }
                .frame(height: 8)
                .offset(x: gaze * 5)
                .animation(.easeOut(duration: 0.15), value: gaze)
            GeometryReader { g in
                Capsule().fill(Theme.pink).frame(width: fill ? g.size.width : 0, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .opacity(nudge ? 0 : 1)
        }
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { shown = true }
            if !nudge { withAnimation(.linear(duration: dwell)) { fill = true } }
            guard !reduceMotion else { return }
            let waits = nudge ? [0.7, 1.1, 0.2] : [min(dwell, Theme.dwell) * 0.5]
            Task {
                for w in waits {
                    try? await Task.sleep(for: .seconds(w))
                    withAnimation(.easeInOut(duration: 0.06)) { blink = true }
                    try? await Task.sleep(for: .seconds(0.09))
                    withAnimation(.easeInOut(duration: 0.08)) { blink = false }
                }
            }
        }
    }

    private var eye: some View {
        Capsule().fill(Color.white)
            .frame(width: 6, height: blink ? 1.5 : 6)
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
    }
}


// MARK: - Windows

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Can take keyboard focus without activating the app, so ⌃⌥C can drive the panel while you stay in your work.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class NotchController {
    private var panel: KeyPanel?
    private var openRect = NSRect.zero
    private var spotlight: NSWindow?
    private var overlay: OverlayState?
    private var model: PlayerModel?
    private var overlayMonitors: [Any] = []
    private var panelKeyMonitor: Any?
    private var keyboardPanel = false
    private var mouseMonitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private var timer: Timer?
    private var hoverStart: Date?
    private var hoverDwell = Theme.dwell
    private var leaveStart: Date?
    private var cooldownUntil = Date.distantPast
    private var warmTask: Task<Void, Never>?
    private var reminderTimer: Timer?
    private var activeMinutes = 0
    private var swipeTravel: CGFloat = 0
    private var swipeFired = false
    private let state = NotchState()
    /// Remaining Focus Boost time for the menu bar, or nil when none is running.
    var statusTick: ((TimeInterval?) -> Void)?

    private var panelOpen: Bool { state.phase == .open }

    /// Mouse-move events wake the hover check; the 20 Hz timer only runs while a hover or the panel is in progress.
    func start() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.tick() }
            return e
        }) { mouseMonitors.append(l) }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            let window = n.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, self.keyboardPanel, window === self.panel else { return }
                self.hidePanel()
            }
        }
        warm()
        scheduleReminders()
    }

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Overlays open on whichever screen the pointer is on.
    private func overlayScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? notchScreen()
    }

    private func notchHeight(_ s: NSScreen) -> CGFloat { s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : 24 }

    /// The notch itself, or a stand-in strip at top-center on screens without one.
    private func notchRect(_ s: NSScreen) -> NSRect {
        let top = s.frame.maxY
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let x0 = s.frame.minX + l.width
            let x1 = s.frame.maxX - r.width
            return NSRect(x: x0, y: top - s.safeAreaInsets.top, width: x1 - x0, height: s.safeAreaInsets.top)
        }
        return NSRect(x: s.frame.midX - 90, y: top - 24, width: 180, height: 24)
    }

    /// The notch, padded a few points; a thin strip at top-center on screens without one.
    private func hotZone(_ s: NSScreen) -> NSRect {
        if s.safeAreaInsets.top > 0 {
            let n = notchRect(s)
            return NSRect(x: n.minX - 6, y: n.minY, width: n.width + 12, height: n.height + 4)
        }
        return NSRect(x: s.frame.midX - 110, y: s.frame.maxY - 6, width: 220, height: 10)
    }

    /// Converts a screen rect to the top-left coordinates of a window covering `s`.
    private func local(_ r: NSRect, in s: NSScreen) -> CGRect {
        CGRect(x: r.minX - s.frame.minX, y: s.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// True when the front app fills this screen: a full-screen app, a slideshow, a shared screen, a game.
    /// Then the notch waits for a longer, deliberate hover. Window bounds need no Screen Recording permission.
    private func frontAppIsFullScreen(on s: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d as CFDictionary)
            else { continue }
            let r = CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
            if r.width >= s.frame.width - 1, r.height >= s.frame.height - 1, r.intersects(s.frame) { return true }
        }
        return false
    }

    private func tick() {
        defer { updateTimer() }
        guard spotlight == nil, let screen = notchScreen() else { return }
        let p = NSEvent.mouseLocation
        let hot = hotZone(screen)
        if panelOpen {
            if keyboardPanel { return }
            let inside = openRect.insetBy(dx: -8, dy: -8).contains(p) || hot.contains(p)
            if inside { leaveStart = nil }
            else if let s = leaveStart { if Date().timeIntervalSince(s) > 0.35 { hidePanel() } }
            else { leaveStart = Date() }
        } else if hot.contains(p) && Date() > cooldownUntil {
            let gaze = max(-1, min(1, (p.x - hot.midX) / max(1, hot.width / 2)))
            if let s = hoverStart {
                if Date().timeIntervalSince(s) > hoverDwell { openPanel(on: screen) }
                else if abs(gaze - state.gaze) > 0.03 { state.gaze = gaze }
            } else {
                hoverStart = Date()
                hoverDwell = frontAppIsFullScreen(on: screen) ? Theme.deliberateDwell : Theme.dwell
                state.gaze = gaze
                peek(on: screen)
            }
        } else if hoverStart != nil {
            hoverStart = nil
            unpeek()
        }
    }

    private func updateTimer() {
        let needed = spotlight == nil && (panelOpen || hoverStart != nil)
        if needed, timer == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    // MARK: Notch panel

    private func preparePanel(on screen: NSScreen) {
        let nh = notchHeight(screen)
        let notch = notchRect(screen)
        let cards = CGFloat(panelCards().count)
        let w = min(max(cards * cardWidth + (cards - 1) * cardSpacing + 36, 640), screen.frame.width - 80)
        let h = nh + 172
        state.notchSize = CGSize(width: notch.width, height: screen.safeAreaInsets.top)
        state.panelSize = CGSize(width: w, height: h)
        state.notchHeight = nh
        openRect = NSRect(x: notch.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        let margin: CGFloat = 40  // room for the glow
        let frame = NSRect(x: openRect.minX - margin, y: openRect.minY - margin, width: w + margin * 2, height: h + margin)
        if panel == nil {
            let p = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isMovable = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let hv = FirstMouseHostingView(rootView: NotchGalleryView(
                state: state,
                onPick: { [weak self] c, r in self?.pick(c, from: r) },
                onAbout: { [weak self] in self?.openResearch() }))
            hv.sizingOptions = []
            p.contentView = hv
            panel = p
        }
        panel?.setFrame(frame, display: false)
    }

    private func peek(on screen: NSScreen) {
        preparePanel(on: screen)
        state.dwell = hoverDwell
        panel?.ignoresMouseEvents = true
        panel?.orderFrontRegardless()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { state.phase = .peek }
    }

    private func unpeek() {
        guard state.phase == .peek else { return }
        withAnimation(.easeIn(duration: 0.15)) { state.phase = .hidden }
        orderOutPanel(after: 0.2)
    }

    private func openPanel(on screen: NSScreen) {
        if state.phase != .peek {
            preparePanel(on: screen)
            panel?.orderFrontRegardless()
        }
        hoverStart = nil
        leaveStart = nil
        panel?.ignoresMouseEvents = false
        withAnimation(Theme.reduceMotion ? .easeOut(duration: 0.15) : Theme.open) { state.phase = .open }
        refreshThumbs()
        warm()
    }

    private func hidePanel() {
        guard panelOpen else { return }
        if let k = panelKeyMonitor { NSEvent.removeMonitor(k); panelKeyMonitor = nil }
        keyboardPanel = false
        state.selected = nil
        leaveStart = nil
        hoverStart = nil
        panel?.ignoresMouseEvents = true
        withAnimation(Theme.reduceMotion ? .easeIn(duration: 0.12) : Theme.settle) { state.phase = .hidden }
        orderOutPanel(after: 0.35)
    }

    /// ⌃⌥C: opens the panel for the keyboard (← → or 1–8 to choose, Return to open, Esc to close),
    /// or closes whatever is already open.
    func toggleFromHotkey() {
        if spotlight != nil { closeSpotlight(); return }
        if panelOpen { hidePanel(); return }
        guard let screen = notchScreen() else { return }
        openPanel(on: screen)
        keyboardPanel = true
        state.selected = boostCategory.id
        panel?.makeKey()
        panelKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            return MainActor.assumeIsolated { self?.panelKey(code) ?? false } ? nil : e
        }
    }

    private func panelKey(_ code: UInt16) -> Bool {
        let cards = panelCards()
        let i = cards.firstIndex { $0.id == state.selected } ?? 0
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]  // 1–8 on the number row
        switch code {
        case 123: state.selected = cards[max(0, i - 1)].id
        case 124: state.selected = cards[min(cards.count - 1, i + 1)].id
        case 36, 76: pick(cards[i], from: nil)
        case 53: hidePanel()
        default:
            guard let n = digits.firstIndex(of: code), n < cards.count else { return false }
            pick(cards[n], from: nil)
        }
        return true
    }

    /// A pink pulse around the notch when a Focus Boost lands back in it.
    private func glowNotch() {
        guard let screen = notchScreen() else { return }
        preparePanel(on: screen)
        panel?.ignoresMouseEvents = true
        panel?.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.25)) { state.phase = .glow }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard let self, self.state.phase == .glow else { return }
            withAnimation(.easeIn(duration: 0.6)) { self.state.phase = .hidden }
            self.orderOutPanel(after: 0.65)
        }
    }

    private func orderOutPanel(after secs: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            guard let self, self.state.phase == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func pick(_ c: CuteCategory, from r: CGRect?) {
        Theme.haptic()
        let origin = r.flatMap { r in panel.map { NSRect(x: $0.frame.minX + r.minX, y: $0.frame.maxY - r.maxY, width: r.width, height: r.height) } }
        if c.id == boostCategory.id { openBoost(from: origin) } else { openSpotlight(c, from: origin, lead: state.thumbItems[c.id]) }
    }

    // MARK: Break reminders

    /// Opt-in. Once a minute, counts minutes of steady input; after about 50, the notch's eyes peek out and blink
    /// once. No notification, no sound. Five idle minutes, or opening the player, resets the count.
    func scheduleReminders() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        activeMinutes = 0
        guard Prefs.breakReminders else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minuteTick() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        reminderTimer = t
    }

    private func minuteTick() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 300 { activeMinutes = 0; return }
        if idle < 120 { activeMinutes += 1 }
        guard activeMinutes >= 50, spotlight == nil, state.phase == .hidden,
              let s = notchScreen(), !frontAppIsFullScreen(on: s) else { return }
        activeMinutes = 0
        preparePanel(on: s)
        panel?.ignoresMouseEvents = true
        panel?.orderFrontRegardless()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { state.phase = .nudge }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard let self, self.state.phase == .nudge else { return }
            withAnimation(.easeIn(duration: 0.3)) { self.state.phase = .hidden }
            self.orderOutPanel(after: 0.35)
        }
    }

    // MARK: Background feeds and card thumbnails

    /// Refreshes feeds older than an hour, one at a time, so categories open instantly from disk.
    /// Runs at launch and whenever the panel opens; gives way to anything the user is waiting on.
    private func warm() {
        guard warmTask == nil else { return }
        warmTask = Task { [weak self] in
            for c in [boostCategory] + categories {
                if await FeedStore.shared.cached(c).age < 3600 { continue }
                var tries = 0
                while tries < 3 {
                    let wait = await FeedStore.shared.secondsUntilAllowed()
                    try? await Task.sleep(for: .seconds(wait + 1))
                    if await FeedStore.shared.refresh(c, background: true) != nil { break }
                    tries += 1
                }
                if c.id != boostCategory.id { await self?.refreshThumb(c) }
            }
            self?.warmTask = nil
        }
    }

    private func refreshThumbs() {
        Task { [weak self] in
            for c in categories { await self?.refreshThumb(c) }
            await self?.refreshFavoriteStack()
        }
    }

    /// Each card shows a post you haven't seen yet when there is one, and remembers which post it was.
    private func refreshThumb(_ c: CuteCategory) async {
        let items = await FeedStore.shared.cached(c).items.filter { $0.thumb != nil }
        let unseen = items.filter { !Seen.contains($0.url) }
        guard let post = (unseen.isEmpty ? items : unseen).randomElement(), let u = post.thumb,
              let img = await ImageCache.shared.image(u) else { return }
        state.thumbs[c.id] = img
        state.thumbItems[c.id] = post
    }

    private func refreshFavoriteStack() async {
        var posts: [CuteItem] = []
        var images: [NSImage] = []
        for post in Favorites.shared.items.filter({ $0.thumb != nil }).shuffled() where images.count < 3 {
            if let u = post.thumb, let img = await ImageCache.shared.image(u) { posts.append(post); images.append(img) }
        }
        state.favoriteStack = images
        state.thumbItems[favoritesCategory.id] = posts.first
    }

    // MARK: Overlays

    func openSpotlight(_ c: CuteCategory, from origin: NSRect? = nil, lead: CuteItem? = nil) {
        openPlayer(PlayerModel(category: c, lead: lead), from: origin)
    }

    func openBoost(from origin: NSRect? = nil) {
        openPlayer(PlayerModel(category: boostCategory, boostLength: Prefs.boostSeconds), from: origin)
    }

    private func openPlayer(_ m: PlayerModel, from origin: NSRect?) {
        activeMinutes = 0
        m.onBoostDone = { [weak self, weak m] in
            guard let self, let m, self.model === m else { return }
            self.closeSpotlight(glow: true)
        }
        m.onBoostTick = { [weak self] left in self?.statusTick?(left) }
        let ov = presentOverlay(from: origin, maxSize: CGSize(width: 880, height: 680), content: { [weak self] _ in
            SpotlightView(model: m,
                          close: { self?.closeSpotlight() },
                          open: { url in self?.closeSpotlight(); NSWorkspace.shared.open(url) },
                          onShare: { self?.closeSpotlight(reactivate: false) })
        }, keys: { [weak self] code, mods in
            guard let self, let m = self.model else { return false }
            if mods.contains(.command) {
                guard code == 8 else { return false }  // ⌘C
                m.copyCurrent()
                return true
            }
            if !mods.intersection([.control, .option]).isEmpty { return false }
            switch code {
            case 53: self.closeSpotlight()
            case 124: m.next()
            case 123: m.prev()
            case 49: m.togglePause()
            case 46: m.muted.toggle()
            case 3: m.toggleFavorite()
            case 31: if let p = m.current?.permalink { self.closeSpotlight(); NSWorkspace.shared.open(p) }
            default: return false
            }
            return true
        })
        m.onTint = { [weak ov] c in ov?.setTint(c) }
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.swipe(e) }
            return e
        }) { overlayMonitors.append(s) }
        model = m
        m.load()
    }

    /// A two-finger swipe moves between posts: fingers left for the next one, right for the previous.
    private func swipe(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, let m = model else { return }
        if e.phase == .began { swipeTravel = 0; swipeFired = false }
        guard e.phase == .changed, !swipeFired else { return }
        let fingers = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        swipeTravel += fingers
        guard abs(swipeTravel) > 60 else { return }
        swipeFired = true
        if swipeTravel < 0 { m.next() } else { m.prev() }
        Theme.haptic(.alignment)
    }

    func openResearch() {
        presentOverlay(from: nil, maxSize: CGSize(width: 640, height: 640), content: { [weak self] _ in
            ResearchView(close: { self?.closeSpotlight() })
        }, keys: { [weak self] code, _ in
            guard code == 53 else { return false }
            self?.closeSpotlight()
            return true
        })
    }

    @discardableResult
    private func presentOverlay<V: View>(from origin: NSRect?, maxSize: CGSize, content: (CGSize) -> V,
                                         keys: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool) -> OverlayState? {
        hidePanel()
        if spotlight != nil { closeSpotlight() }
        guard let screen = overlayScreen() else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previousApp = front }
        let size = CGSize(width: min(maxSize.width, screen.frame.width - 80), height: min(maxSize.height, screen.frame.height - 120))
        let ov = OverlayState(origin: local(origin ?? notchRect(screen), in: screen))
        let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hv = FirstMouseHostingView(rootView: Presented(overlay: ov, cardSize: size, close: { [weak self] in self?.closeSpotlight() }, content: content(size)))
        hv.sizingOptions = []
        w.contentView = hv
        spotlight = w
        overlay = ov
        updateTimer()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(Theme.reduceMotion ? .easeOut(duration: 0.2) : Theme.open) { ov.presented = true }
        }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            let code = e.keyCode
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return MainActor.assumeIsolated { keys(code, mods) } ? nil : e
        }) { overlayMonitors.append(k) }
        return ov
    }

    /// Shrinks the card back into the notch; after a finished Focus Boost the notch glows as it lands.
    /// When a share was chosen, NotchCute stays in front so the share sheet can appear.
    func closeSpotlight(glow: Bool = false, reactivate: Bool = true) {
        overlayMonitors.forEach(NSEvent.removeMonitor)
        overlayMonitors = []
        model?.stop()
        model = nil
        statusTick?(nil)
        cooldownUntil = Date().addingTimeInterval(1.0)
        guard let w = spotlight, let ov = overlay else { return }
        spotlight = nil
        overlay = nil
        if let s = w.screen { ov.origin = local(notchRect(s), in: s) }
        withAnimation(Theme.reduceMotion ? .easeIn(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.9)) { ov.presented = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            w.contentView = nil
            w.orderOut(nil)
            if glow { self?.glowNotch() }
        }
        if reactivate { previousApp?.activate(options: []) }
    }
}


// MARK: - Global hotkey

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hk.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x4E43_4854), id: 1)  // 'NCHT'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = NotchController()
    var statusItem: NSStatusItem?
    var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = si.button {
            b.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "NotchCute")
            b.image?.isTemplate = true
            b.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        si.menu = menu
        statusItem = si
        controller.statusTick = { [weak self] left in self?.showCountdown(left) }
        hotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in self?.controller.toggleFromHotkey() }
    }

    /// During a Focus Boost the paw carries the time left.
    private func showCountdown(_ left: TimeInterval?) {
        guard let b = statusItem?.button else { return }
        let text = left.map { " " + clock($0) } ?? ""
        guard b.title != text else { return }
        b.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    /// Rebuilt on every open so Favorites, Launch at Login and the boost length stay current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Hover the notch, or press ⌃⌥C", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(item("🎯  Focus Boost (\(Prefs.label(Prefs.boostSeconds)))", #selector(boost)))
        for (i, c) in categories.enumerated() {
            let mi = item("\(c.emoji)  \(c.name)", #selector(pick(_:)))
            mi.tag = i
            menu.addItem(mi)
        }
        let favCount = Favorites.shared.items.count
        if favCount > 0 { menu.addItem(item("❤️  Favorites (\(favCount))", #selector(favorites))) }
        menu.addItem(.separator())

        let lengths = NSMenu()
        for s in Prefs.boostChoices {
            let mi = item(Prefs.label(s), #selector(setBoostLength(_:)))
            mi.tag = Int(s)
            mi.state = Prefs.boostSeconds == s ? .on : .off
            lengths.addItem(mi)
        }
        let lengthItem = NSMenuItem(title: "Focus Boost Length", action: nil, keyEquivalent: "")
        lengthItem.submenu = lengths
        menu.addItem(lengthItem)
        let reminders = item("Gentle Break Reminders", #selector(toggleReminders))
        reminders.state = Prefs.breakReminders ? .on : .off
        reminders.toolTip = "After about 50 minutes of steady work, the notch peeks out and blinks once. Nothing else."
        menu.addItem(reminders)
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Why cute things help…", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchCute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc func pick(_ sender: NSMenuItem) { controller.openSpotlight(categories[sender.tag]) }
    @objc func boost() { controller.openBoost() }
    @objc func favorites() { controller.openSpotlight(favoritesCategory) }
    @objc func about() { controller.openResearch() }
    @objc func setBoostLength(_ sender: NSMenuItem) { Prefs.boostSeconds = Double(sender.tag) }

    @objc func toggleReminders() {
        Prefs.breakReminders.toggle()
        controller.scheduleReminders()
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
            if s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = "\(error.localizedDescription)\n\nMoving NotchCute to your Applications folder usually fixes this."
            NSApp.activate()
            a.runModal()
        }
    }
}

@main @MainActor enum NotchCuteMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
