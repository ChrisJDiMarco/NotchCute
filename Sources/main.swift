// NotchCute: hover the MacBook notch, pick a cute category, watch cute things.
import AppKit
import SwiftUI
import AVFoundation
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
let pink = Color(red: 1.0, green: 0.62, blue: 0.72)

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
    let category: CuteCategory
    let boostLength: TimeInterval?
    @Published private(set) var items: [CuteItem] = []
    @Published private(set) var index = 0
    @Published var status = "Fetching cute things…"
    @Published private(set) var paused = false
    @Published var muted = true
    @Published private(set) var boostLeft: TimeInterval = 0
    @Published private(set) var boostDone = false
    var onBoostDone: (() -> Void)?

    private var startedItem: CuteItem?
    private var everStarted = false
    private var deadline: Date?
    private var remaining: TimeInterval?
    private var advanceTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var boostTask: Task<Void, Never>?

    init(category: CuteCategory, boostLength: TimeInterval? = nil) {
        self.category = category
        self.boostLength = boostLength
        self.boostLeft = boostLength ?? 0
    }

    var current: CuteItem? { items.indices.contains(index) ? items[index] : nil }

    func load() {
        startBoost()
        if category.id == favoritesCategory.id {
            merge(Favorites.shared.items)
            if items.isEmpty { status = "No favorites yet. Press F or ♥ on anything you love." }
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let cached = await FeedStore.shared.cached(self.category)
            self.merge(cached.items)
            guard cached.age > FeedStore.freshFor else { return }
            if self.items.isEmpty {
                let wait = await FeedStore.shared.secondsUntilAllowed()
                if wait > 3 { self.status = "Reddit asked for a short break. Trying again in about \(Int(wait.rounded())) s…" }
            }
            let fresh = await FeedStore.shared.refresh(self.category)
            if Task.isCancelled { return }
            if let fresh { self.merge(fresh) }
            if self.items.isEmpty { self.status = "Reddit didn't send anything just now. Close and try again in a minute." }
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
        startAdvance(after: item.isVideo ? 300 : 8)
    }

    func ended(_ item: CuteItem) { if current == item { next() } }

    func failed(_ item: CuteItem) {
        guard let i = items.firstIndex(of: item) else { return }
        let wasCurrent = i == index
        items.remove(at: i)
        if items.isEmpty { index = 0; status = "Couldn't load anything from this category right now."; didChangeCurrent(); return }
        if i < index { index -= 1 }
        else if wasCurrent { if index >= items.count { index = 0 }; didChangeCurrent() }
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
        boostTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if self.paused || !self.everStarted { continue }
                self.boostLeft = max(0, self.boostLeft - 0.1)
                if self.boostLeft == 0 { self.finishBoost(); return }
            }
        }
    }

    private func finishBoost() {
        advanceTask?.cancel()
        watchdogTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { boostDone = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            self?.onBoostDone?()
        }
    }

    func stop() { advanceTask?.cancel(); watchdogTask?.cancel(); loadTask?.cancel(); boostTask?.cancel() }
}

// MARK: - Media views

struct ImageMedia: NSViewRepresentable {
    let url: URL
    let onReady: () -> Void
    let onFail: () -> Void
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        let url = self.url
        let onReady = self.onReady
        let onFail = self.onFail
        Task { @MainActor in
            if let img = await ImageCache.shared.image(url) { v.image = img; onReady() } else { onFail() }
        }
        return v
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

final class PlayerNSView: NSView {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var startedAt: Date?
    private var paused: Bool
    private let onReady: () -> Void
    private let onEnd: () -> Void
    private let onFail: () -> Void

    init(url: URL, paused: Bool, muted: Bool, onReady: @escaping () -> Void, onEnd: @escaping () -> Void, onFail: @escaping () -> Void) {
        self.paused = paused
        self.onReady = onReady
        self.onEnd = onEnd
        self.onFail = onFail
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
        let item = AVPlayerItem(asset: asset)
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
        if !paused { player.play() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Short clips loop until they've had 8 s on screen, so a 3 s GIF doesn't flash by.
    private func reachedEnd() {
        if let s = startedAt, Date().timeIntervalSince(s) < 8 {
            player.seek(to: .zero)
            if !paused { player.play() }
            return
        }
        onEnd()
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
        CATransaction.commit()
    }

    func teardown() {
        player.pause()
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
    func makeNSView(context: Context) -> PlayerNSView {
        PlayerNSView(url: url, paused: paused, muted: muted, onReady: onReady, onEnd: onEnd, onFail: onFail)
    }
    func updateNSView(_ nsView: PlayerNSView, context: Context) { nsView.apply(paused: paused, muted: muted) }
    static func dismantleNSView(_ nsView: PlayerNSView, coordinator: ()) { nsView.teardown() }
}

// MARK: - Spotlight (dimmed screen + centered player)

struct SpotlightView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var favorites = Favorites.shared
    let cardSize: CGSize
    let close: () -> Void
    let open: (URL) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                header
                media
                footer
            }
            .foregroundColor(.white)
            .frame(width: cardSize.width, height: cardSize.height)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 40)
            .contentShape(Rectangle())
            .onTapGesture {}
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("\(model.category.emoji)  \(model.category.name)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                if model.boostLength != nil {
                    Text(clock(model.boostLeft)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().opacity(0.7)
                } else if let item = model.current, !item.subreddit.isEmpty {
                    Text("r/\(item.subreddit)").font(.system(size: 13, design: .rounded)).opacity(0.6)
                }
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
            }
            if let len = model.boostLength {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(pink).frame(width: (cardSize.width - 32) * (1 - model.boostLeft / len))
                            .animation(.linear(duration: 0.1), value: model.boostLeft)
                    }
            }
        }
        .padding(16)
    }

    private var media: some View {
        ZStack {
            Color.black
            if let item = model.current {
                Group {
                    if item.isVideo {
                        VideoMedia(url: item.url, paused: model.paused || model.boostDone, muted: model.muted,
                                   onReady: { model.ready(item) }, onEnd: { model.ended(item) }, onFail: { model.failed(item) })
                    } else {
                        ImageMedia(url: item.url, onReady: { model.ready(item) }, onFail: { model.failed(item) })
                    }
                }
                .id(item.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(model.status).font(.system(size: 14, design: .rounded)).opacity(0.8).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
            }
            if model.paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            if model.boostDone {
                VStack(spacing: 8) {
                    Text("✨").font(.system(size: 52))
                    Text("That's your boost.").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Now go do the careful stuff.").font(.system(size: 15, design: .rounded)).opacity(0.75)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.78))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let item = model.current {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .lineLimit(2)
                    if item.permalink != nil {
                        HStack(spacing: 4) {
                            if let a = item.author { Text("u/\(a)  ·").opacity(0.55) }
                            Text("Open on Reddit ›").foregroundColor(pink)
                        }
                        .font(.system(size: 12, design: .rounded))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let p = item.permalink { open(p) } }
                .help(item.permalink == nil ? "" : "Open this post on Reddit (O)")
                Spacer(minLength: 12)
                let fav = favorites.contains(item)
                circleButton(fav ? "heart.fill" : "heart", tint: fav ? pink : .white, help: "Favorite (F)") { favorites.toggle(item) }
                if item.isVideo {
                    circleButton(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: "Sound (M)") { model.muted.toggle() }
                }
            } else {
                Spacer()
            }
            circleButton(model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume (Space)" : "Pause (Space)") { model.togglePause() }
            circleButton("chevron.left", help: "Previous (←)") { model.prev() }
            circleButton("chevron.right", help: "Next (→)") { model.next() }
        }
        .padding(16)
    }

    private func circleButton(_ symbol: String, tint: Color = .white, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Research modal

struct ResearchView: View {
    let cardSize: CGSize
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack {
                    Text("Why NotchCute exists").font(.system(size: 21, weight: .bold, design: .rounded))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain)
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
                        .tint(pink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                }
            }
            .foregroundColor(.white)
            .frame(width: cardSize.width, height: cardSize.height)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 40)
            .contentShape(Rectangle())
            .onTapGesture {}
        }
    }

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(pink)
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

@MainActor final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var thumbs: [String: NSImage] = [:]
}

let cardWidth: CGFloat = 96
let cardSpacing: CGFloat = 10

struct NotchGalleryView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var favorites = Favorites.shared
    let notchHeight: CGFloat
    let onPick: (CuteCategory) -> Void
    let onBoost: () -> Void
    let onAbout: () -> Void
    @State private var hovered: String?
    @State private var aboutHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchHeight)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    card(boostCategory, sub: Prefs.label(Prefs.boostSeconds), accent: true) { onBoost() }
                    ForEach(categories) { c in card(c) { onPick(c) } }
                    if !favorites.items.isEmpty {
                        card(favoritesCategory, sub: "\(favorites.items.count)") { onPick(favoritesCategory) }
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
                    .foregroundColor(pink)
                    .underline(aboutHovered)
            }
            .font(.system(size: 12, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { aboutHovered = $0 }
            .onTapGesture { onAbout() }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 28, bottomTrailingRadius: 28, topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
        )
        .scaleEffect(x: state.expanded ? 1 : 0.3, y: state.expanded ? 1 : 0.15, anchor: .top)
        .opacity(state.expanded ? 1 : 0)
    }

    private func card(_ c: CuteCategory, sub: String? = nil, accent: Bool = false, action: @escaping () -> Void) -> some View {
        let isHovered = hovered == c.id
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            if accent {
                LinearGradient(colors: [pink, Color(red: 0.98, green: 0.45, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color.white.opacity(isHovered ? 0.2 : 0.08)
            }
            if let t = state.thumbs[c.id] {
                Image(nsImage: t).resizable().scaledToFill().frame(width: cardWidth, height: 112).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.emoji).font(.system(size: 18))
                    Text(c.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                }
                .padding(8)
            } else {
                VStack(spacing: 5) {
                    Text(c.emoji).font(.system(size: 40))
                    Text(c.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                    if let sub { Text(sub).font(.system(size: 10, weight: .medium, design: .rounded)).opacity(0.75) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundColor(.white)
        .frame(width: cardWidth, height: 112)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(isHovered ? 0.55 : 0), lineWidth: 1.5))
        .scaleEffect(isHovered ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .contentShape(Rectangle())
        .onHover { h in if h { hovered = c.id } else if hovered == c.id { hovered = nil } }
        .onTapGesture(perform: action)
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

@MainActor final class NotchController {
    private var panel: NSPanel?
    private var panelShown = false
    private var spotlight: NSWindow?
    private var model: PlayerModel?
    private var keyMonitor: Any?
    private var mouseMonitors: [Any] = []
    private var previousApp: NSRunningApplication?
    private var timer: Timer?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var cooldownUntil = Date.distantPast
    private var warmTask: Task<Void, Never>?
    private let state = NotchState()

    /// Mouse-move events wake the hover check; the 20 Hz timer only runs while a hover or the panel is in progress.
    func start() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.tick() }
            return e
        }) { mouseMonitors.append(l) }
        warm()
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

    /// The notch itself, padded a few points; a thin strip at top-center on screens without one.
    private func hotZone(_ s: NSScreen) -> NSRect {
        let top = s.frame.maxY
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let x0 = s.frame.minX + l.width
            let x1 = s.frame.maxX - r.width
            let h = s.safeAreaInsets.top
            return NSRect(x: x0 - 6, y: top - h, width: (x1 - x0) + 12, height: h + 4)
        }
        return NSRect(x: s.frame.midX - 110, y: top - 6, width: 220, height: 10)
    }

    private func tick() {
        defer { updateTimer() }
        guard spotlight == nil, let screen = notchScreen() else { return }
        let p = NSEvent.mouseLocation
        let hot = hotZone(screen)
        if panelShown {
            let inside = (panel?.frame.insetBy(dx: -8, dy: -8).contains(p) ?? false) || hot.contains(p)
            if inside { leaveStart = nil }
            else if let s = leaveStart { if Date().timeIntervalSince(s) > 0.35 { hidePanel() } }
            else { leaveStart = Date() }
        } else if hot.contains(p) && Date() > cooldownUntil {
            if let s = hoverStart { if Date().timeIntervalSince(s) > 0.3 { showPanel(on: screen) } }
            else { hoverStart = Date() }
        } else {
            hoverStart = nil
        }
    }

    private func updateTimer() {
        let needed = spotlight == nil && (panelShown || hoverStart != nil)
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

    private func showPanel(on screen: NSScreen) {
        let nh = notchHeight(screen)
        let cards = CGFloat(categories.count + 1 + (Favorites.shared.items.isEmpty ? 0 : 1))
        let w = min(max(cards * cardWidth + (cards - 1) * cardSpacing + 36, 640), screen.frame.width - 40)
        let h: CGFloat = nh + 172
        let frame = NSRect(x: hotZone(screen).midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isMovable = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let hv = FirstMouseHostingView(rootView: NotchGalleryView(
                state: state, notchHeight: nh,
                onPick: { [weak self] c in self?.openSpotlight(c) },
                onBoost: { [weak self] in self?.openBoost() },
                onAbout: { [weak self] in self?.openResearch() }))
            hv.sizingOptions = []
            p.contentView = hv
            panel = p
        }
        panel?.setFrame(frame, display: true)
        panelShown = true
        hoverStart = nil
        leaveStart = nil
        state.expanded = false
        panel?.orderFrontRegardless()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self, self.panelShown else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { self.state.expanded = true }
        }
        refreshThumbs()
        warm()
    }

    private func hidePanel() {
        guard panelShown else { return }
        panelShown = false
        leaveStart = nil
        hoverStart = nil
        withAnimation(.easeIn(duration: 0.16)) { state.expanded = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !self.panelShown else { return }
            self.panel?.orderOut(nil)
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
            await self?.refreshThumb(favoritesCategory)
        }
    }

    private func refreshThumb(_ c: CuteCategory) async {
        let items: [CuteItem]
        if c.id == favoritesCategory.id { items = Favorites.shared.items } else { items = await FeedStore.shared.cached(c).items }
        guard let u = items.compactMap(\.thumb).randomElement(), let img = await ImageCache.shared.image(u) else { return }
        state.thumbs[c.id] = img
    }

    // MARK: Overlays

    func openSpotlight(_ c: CuteCategory) { openPlayer(PlayerModel(category: c)) }

    func openBoost() { openPlayer(PlayerModel(category: boostCategory, boostLength: Prefs.boostSeconds)) }

    func toggleBoost() { if spotlight != nil { closeSpotlight() } else { openBoost() } }

    private func openPlayer(_ m: PlayerModel) {
        m.onBoostDone = { [weak self, weak m] in
            guard let self, let m, self.model === m else { return }
            self.closeSpotlight()
        }
        presentOverlay(maxSize: CGSize(width: 880, height: 680), content: { [weak self] size in
            SpotlightView(model: m, cardSize: size,
                          close: { self?.closeSpotlight() },
                          open: { url in self?.closeSpotlight(); NSWorkspace.shared.open(url) })
        }, keys: { [weak self] code in
            guard let self, let m = self.model else { return false }
            switch code {
            case 53: self.closeSpotlight()
            case 124: m.next()
            case 123: m.prev()
            case 49: m.togglePause()
            case 46: m.muted.toggle()
            case 3: if let i = m.current { Favorites.shared.toggle(i) }
            case 31: if let p = m.current?.permalink { self.closeSpotlight(); NSWorkspace.shared.open(p) }
            default: return false
            }
            return true
        })
        model = m
        m.load()
    }

    func openResearch() {
        presentOverlay(maxSize: CGSize(width: 640, height: 640), content: { [weak self] size in
            ResearchView(cardSize: size, close: { self?.closeSpotlight() })
        }, keys: { [weak self] code in
            guard code == 53 else { return false }
            self?.closeSpotlight()
            return true
        })
    }

    private func presentOverlay<V: View>(maxSize: CGSize, content: (CGSize) -> V, keys: @escaping @MainActor (UInt16) -> Bool) {
        hidePanel()
        if spotlight != nil { closeSpotlight() }
        guard let screen = overlayScreen() else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previousApp = front }
        let size = CGSize(width: min(maxSize.width, screen.frame.width - 80), height: min(maxSize.height, screen.frame.height - 120))
        let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hv = FirstMouseHostingView(rootView: content(size))
        hv.sizingOptions = []
        w.contentView = hv
        w.alphaValue = 0
        spotlight = w
        updateTimer()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 1
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
            let code = e.keyCode
            return MainActor.assumeIsolated { keys(code) } ? nil : e
        }
    }

    func closeSpotlight() {
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        model?.stop()
        model = nil
        cooldownUntil = Date().addingTimeInterval(1.0)
        guard let w = spotlight else { return }
        spotlight = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                w.contentView = nil
                w.orderOut(nil)
            }
        })
        previousApp?.activate(options: [])
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
        si.button?.title = "🐾"
        let menu = NSMenu()
        menu.delegate = self
        si.menu = menu
        statusItem = si
        hotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in self?.controller.toggleBoost() }
    }

    /// Rebuilt on every open so Favorites, Launch at Login and the boost length stay current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Hover the notch, or pick one:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let boostItem = item("🎯  Focus Boost (\(Prefs.label(Prefs.boostSeconds)))", #selector(boost), key: "c")
        boostItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(boostItem)
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
