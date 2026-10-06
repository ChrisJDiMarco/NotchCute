// NotchCute: hover the MacBook notch, pick a cute category, watch cute things.
import AppKit
import SwiftUI
import AVFoundation
import CoreImage
import Vision
import Network
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
    /// Low Power Mode: no background refreshes and no slow zoom.
    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// Late at night the backdrop is a little darker and warmer.
    static var lateNight: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 23 || h < 6
    }
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

/// Reddit titles, tidied: no "[OC]" tags, trailing hashtags, doubled punctuation or emoji pile-ups, and curly quotes.
func cleanTitle(_ raw: String) -> String {
    var t = raw
    for pattern in [#"(?i)[\[\(]\s*oc\s*[\]\)]"#, #"(?i)^\s*oc\s*[:\-–—]\s*"#, #"(\s*#\w+)+\s*$"#] {
        t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    t = t.replacingOccurrences(of: #"([!?])\1+"#, with: "$1", options: .regularExpression)
    // At most two emoji in a row.
    var out = ""
    var run = 0
    for ch in t {
        let emoji = ch.unicodeScalars.first.map { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && ch.unicodeScalars.count > 1) } ?? false
        run = emoji ? run + 1 : (ch == " " ? run : 0)
        if emoji && run > 2 { continue }
        out.append(ch)
    }
    t = out
    t = t.replacingOccurrences(of: #"(^|[\s(\[])""#, with: "$1\u{201C}", options: .regularExpression)
    t = t.replacingOccurrences(of: "\"", with: "\u{201D}")
    t = t.replacingOccurrences(of: #"(^|[\s(\[])'"#, with: "$1\u{2018}", options: .regularExpression)
    t = t.replacingOccurrences(of: "'", with: "\u{2019}")
    t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? raw : t
}

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
        CuteItem(title: cleanTitle(e.title), url: url, isVideo: video, subreddit: e.sub, permalink: URL(string: e.link), author: e.author.isEmpty ? nil : e.author, thumb: thumb)
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

/// Fully decodes a picture, scaled down to at most `maxPixels` on its long side, so showing it never stalls an
/// animation and a huge photo never sits in memory at full size. GIFs stay as they are so they animate.
func decodeImage(_ data: Data, isGIF: Bool, maxPixels: Int) -> NSImage? {
    if isGIF { return NSImage(data: data) }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return NSImage(data: data) }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

@MainActor final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    init() { cache.countLimit = 60 }

    /// Downloads, then decodes off the main thread.
    func image(_ url: URL) async -> NSImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let t = inflight[url] { return await t.value }
        let isGIF = url.pathExtension.lowercased() == "gif"
        let t = Task<NSImage?, Never> {
            guard let data = try? await fetchData(url) else { return nil }
            return await Task.detached(priority: .userInitiated) { decodeImage(data, isGIF: isGIF, maxPixels: 2400) }.value
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// Called when the player closes, so NotchCute idles at almost nothing. Card thumbnails stay, so the next
    /// opening is still instant.
    func purge(keeping keep: [URL: NSImage]) {
        cache.removeAllObjects()
        for (u, img) in keep { cache.setObject(img, forKey: u as NSURL) }
    }
}

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
    static let neutral = RGB(r: 0.3, g: 0.3, b: 0.32)
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    func mixed(with o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    func distance(to o: RGB) -> Double { ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() / 3.0.squareRoot() }
}

/// What NotchCute reads from a picture: its light at the top and the bottom (for the backdrop), how bright its
/// bottom edge is (for the shading behind the title), and where the animal is (for framing and the slow zoom).
struct Look: Equatable {
    var top: RGB
    var bottom: RGB
    var bottomLuma: Double
    /// Unit coordinates, top-left origin.
    var focus: CGPoint
    var average: RGB { top.mixed(with: bottom, 0.5) }
}

/// Lifts an averaged color into a glow: same hue, a little more saturation, and brightness held in a narrow
/// band so one post's light never jolts into the next.
func liftToGlow(_ c: RGB) -> RGB {
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    let lifted = NSColor(hue: h, saturation: min(0.75, s * 1.35 + 0.08), brightness: min(0.85, max(0.5, v * 1.25)), alpha: 1)
    guard let out = lifted.usingColorSpace(.sRGB) else { return c }
    return RGB(r: out.redComponent, g: out.greenComponent, b: out.blueComponent)
}

func analyzeImage(_ cg: CGImage) -> Look {
    let n = 8
    var px = [UInt8](repeating: 0, count: n * n * 4)
    _ = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        return true
    }
    // Bitmap rows run top to bottom.
    func average(_ rows: Range<Int>) -> RGB {
        var r = 0.0, g = 0.0, b = 0.0
        for y in rows {
            for x in 0..<n {
                let i = (y * n + x) * 4
                r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2])
            }
        }
        let k = Double(rows.count * n) * 255
        return RGB(r: r / k, g: g / k, b: b / k)
    }
    let bottom = average(5..<8)
    return Look(top: liftToGlow(average(0..<3)), bottom: liftToGlow(bottom), bottomLuma: bottom.luma, focus: findFocus(cg))
}

/// Where the animal is: Vision's cat and dog detector first (aiming at the upper part of the box, where faces
/// are), then its attention-based saliency. Unit point, top-left origin.
func findFocus(_ cg: CGImage) -> CGPoint {
    let handler = VNImageRequestHandler(cgImage: cg)
    let animals = VNRecognizeAnimalsRequest()
    let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
    try? handler.perform([animals, saliency])
    if let box = animals.results?.max(by: { $0.confidence < $1.confidence })?.boundingBox {
        return CGPoint(x: box.midX, y: 1 - (box.minY + box.height * 0.7))
    }
    let salient = saliency.results?.first?.salientObjects ?? []
    if let box = salient.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?.boundingBox {
        return CGPoint(x: box.midX, y: 1 - box.midY)
    }
    return CGPoint(x: 0.5, y: 0.45)
}

@MainActor final class Looks {
    static let shared = Looks()
    private var cache: [URL: Look] = [:]
    private var inflight: [URL: Task<Look?, Never>] = [:]

    func look(_ url: URL) -> Look? { cache[url] }

    func analyze(_ url: URL) async -> Look? {
        if let l = cache[url] { return l }
        if let t = inflight[url] { return await t.value }
        let t = Task<Look?, Never> {
            guard let img = await ImageCache.shared.image(url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return await Task.detached(priority: .utility) { analyzeImage(cg) }.value
        }
        inflight[url] = t
        let l = await t.value
        inflight[url] = nil
        if let l {
            if cache.count > 600 { cache.removeAll() }
            cache[url] = l
        }
        return l
    }
}

/// Keeps the next video loaded and buffering so it starts the moment it's shown.
@MainActor final class VideoPool {
    static let shared = VideoPool()
    private var ready: (url: URL, player: AVPlayer)?

    static func makeItem(_ url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]))
        return item
    }

    func prepare(_ url: URL) {
        guard ready?.url != url else { return }
        ready?.player.replaceCurrentItem(with: nil)
        let p = AVPlayer(playerItem: Self.makeItem(url))
        p.isMuted = true
        ready = (url, p)
    }

    func take(_ url: URL) -> AVPlayer {
        if let r = ready, r.url == url { ready = nil; return r.player }
        return AVPlayer(playerItem: Self.makeItem(url))
    }

    func clear() {
        ready?.player.replaceCurrentItem(with: nil)
        ready = nil
    }
}

/// Watches the connection: offline, or on Low Data Mode or a hotspot, where smaller pictures are kinder.
final class NetworkState: @unchecked Sendable {
    static let shared = NetworkState()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var isOffline = false
    private var isConstrained = false

    var offline: Bool { lock.withLock { isOffline } }
    var constrained: Bool { lock.withLock { isConstrained } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock {
                self.isOffline = path.status != .satisfied
                self.isConstrained = path.isConstrained || path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "notchcute.network"))
    }
}

extension CuteItem {
    /// The picture to show: full size normally; on Low Data Mode or a hotspot, the 640 px preview Reddit already made.
    var stillURL: URL {
        guard NetworkState.shared.constrained, let t = thumb, !(t.query ?? "").contains("width=140") else { return url }
        return t
    }
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

/// A clock whose speed eases toward a target instead of switching at once, so the slow zoom glides to a stop
/// on pause and picks back up on resume.
struct EasedClock {
    private var base = 0.0
    private var v0 = 1.0
    private(set) var target = 1.0
    private var t0 = Date()
    private let tau = 0.18

    func value(at t: Date) -> Double {
        let dt = max(0, t.timeIntervalSince(t0))
        return base + target * dt + (v0 - target) * tau * (1 - exp(-dt / tau))
    }

    private func velocity(at t: Date) -> Double { target + (v0 - target) * exp(-max(0, t.timeIntervalSince(t0)) / tau) }

    mutating func steer(to new: Double, at t: Date = Date()) {
        base = value(at: t)
        v0 = velocity(at: t)
        t0 = t
        target = new
    }

    mutating func restart(running: Bool, at t: Date = Date()) {
        base = 0
        v0 = running ? 1 : 0
        target = v0
        t0 = t
    }

    /// True once a stopped clock has fully settled.
    func resting(at t: Date) -> Bool { target == 0 && t.timeIntervalSince(t0) > 1 }
}

@MainActor final class PlayerModel: ObservableObject {
    enum LoadState: Equatable { case loading, waiting(until: Date), empty(String) }
    static let imageSeconds: TimeInterval = 8
    static let boostEndings: [(title: String, line: String)] = [
        ("That's your boost.", "Now go do the careful stuff."),
        ("All set.", "Eyes sharp, hands steady."),
        ("Nicely done.", "Take that focus with you."),
        ("Boost complete.", "The details are waiting for you."),
        ("There you go.", "Back to it, gently."),
    ]

    let category: CuteCategory
    let boostLength: TimeInterval?
    let ending = PlayerModel.boostEndings.randomElement()!
    @Published private(set) var items: [CuteItem] = []
    @Published private(set) var index = 0
    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var paused = false
    @Published var muted = true
    @Published private(set) var boostLeft: TimeInterval = 0
    @Published private(set) var boostDone = false
    @Published private(set) var hearts = 0
    @Published private(set) var toast: String?
    /// +1 moving forward, -1 back: which way the next post drifts in.
    @Published private(set) var direction = 1
    /// How far a trackpad swipe has dragged the current post, in points.
    @Published var drag: CGFloat = 0
    /// The app a Focus Boost hands you back to.
    var returnApp: NSRunningApplication?
    /// Where the heart button sits, in window coordinates, so a new favorite can fly from it to the notch.
    var heartPoint = CGPoint.zero
    private(set) var zoom = EasedClock()
    var videoProgress: Double = 0
    var onBoostDone: (() -> Void)?
    var onBoostTick: ((TimeInterval) -> Void)?
    var onLook: ((Look) -> Void)?
    var onFavorited: (() -> Void)?

    private var startedItem: CuteItem?
    private var everStarted = false
    private var deadline: Date?
    private var remaining: TimeInterval?
    private var appliedLook: Look?
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
            if NetworkState.shared.offline {
                if self.items.isEmpty { self.loadState = .empty("You're offline. The cute things will be here when you're back.") }
                else { self.showToast("Offline · showing saved posts", for: 2.6) }
                return
            }
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
        prepareAhead()
    }

    func next() {
        guard !items.isEmpty, !boostDone else { return }
        direction = 1
        index = (index + 1) % items.count
        didChangeCurrent()
    }

    func prev() {
        guard !items.isEmpty, !boostDone else { return }
        direction = -1
        index = (index - 1 + items.count) % items.count
        didChangeCurrent()
    }

    /// The clock for an item starts when it's actually on screen, not when it was requested.
    /// The backdrop starts moving to the new post's light right away, from a tint read while it preloaded.
    private func didChangeCurrent() {
        advanceTask?.cancel()
        watchdogTask?.cancel()
        deadline = nil
        remaining = nil
        startedItem = nil
        videoProgress = 0
        guard let item = current else { return }
        if let t = item.thumb, let l = Looks.shared.look(t) { look(l, for: item) }
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.current == item, self.startedItem != item else { return }
            self.failed(item)
        }
        prepareAhead()
    }

    /// Readies the next two posts and the one before: tint, picture fully decoded, or the next video buffering.
    /// A post that fails here is dropped before you ever reach it.
    private func prepareAhead() {
        guard items.count > 1 else { return }
        for (k, step) in [1, 2, -1].enumerated() {
            let it = items[(index + step + items.count) % items.count]
            if let t = it.thumb { Task { _ = await Looks.shared.analyze(t) } }
            if it.isVideo {
                guard k == 0 else { continue }
                VideoPool.shared.prepare(it.url)
                Task { [weak self] in if (try? await fetchData(it.url)) == nil { self?.drop(it) } }
            } else {
                Task { [weak self] in if await ImageCache.shared.image(it.stillURL) == nil { self?.drop(it) } }
            }
        }
    }

    private func drop(_ item: CuteItem) { if current != item { failed(item) } }

    func ready(_ item: CuteItem) {
        guard current == item, startedItem != item else { return }
        startedItem = item
        everStarted = true
        watchdogTask?.cancel()
        Seen.mark(item.url)
        zoom.restart(running: !paused && !boostDone)
        // Videos advance when they end; the long cap only covers a stream that never reports it.
        startAdvance(after: item.isVideo ? 300 : Self.imageSeconds)
    }

    func ended(_ item: CuteItem) { if current == item { Task { await autoAdvance() } } }

    func failed(_ item: CuteItem) {
        guard let i = items.firstIndex(of: item) else { return }
        let wasCurrent = i == index
        items.remove(at: i)
        if items.isEmpty { index = 0; loadState = .empty("Couldn't load anything from this category right now."); didChangeCurrent(); return }
        if i < index { index -= 1 }
        else if wasCurrent { if index >= items.count { index = 0 }; didChangeCurrent() }
    }

    func look(_ l: Look, for item: CuteItem) {
        guard current == item, l != appliedLook else { return }
        appliedLook = l
        onLook?(l)
    }

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
        if Favorites.shared.contains(item) { favorited() }
    }

    /// Double-click: favorites (never un-favorites), like a tap-to-like.
    func favoriteFromDoubleClick() {
        guard let item = current else { return }
        if !Favorites.shared.contains(item) { Favorites.shared.toggle(item); favorited() } else { Theme.haptic() }
    }

    private func favorited() {
        hearts += 1
        Theme.haptic()
        onFavorited?()
    }

    /// ⌘C: the picture itself for stills, the post's link for videos.
    func copyCurrent() {
        guard let item = current else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !item.isVideo, let img = ImageCache.shared.cached(item.stillURL) {
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
        if !item.isVideo, let img = ImageCache.shared.cached(item.stillURL) { out.append(img) }
        out.append(item.permalink ?? item.url)
        return out
    }

    private func showToast(_ text: String, for secs: Double = 1.4) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
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
            await self?.autoAdvance()
        }
    }

    /// The timer's advance. Holds the current post (a few seconds at most) until the next picture is ready, so it
    /// never cuts to an empty frame, and never changes the picture in a Focus Boost's last two seconds.
    private func autoAdvance() async {
        guard items.count > 1, !boostDone else { return }
        if boostLength != nil && boostLeft < 2.5 { return }
        let upcoming = items[(index + 1) % items.count]
        if !upcoming.isVideo {
            let until = Date().addingTimeInterval(4)
            while ImageCache.shared.cached(upcoming.stillURL) == nil && Date() < until && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        if Task.isCancelled { return }
        next()
    }

    func togglePause() {
        guard !boostDone else { return }
        paused.toggle()
        if paused {
            if let d = deadline { remaining = max(0.5, d.timeIntervalSinceNow) }
            advanceTask?.cancel()
            deadline = nil
            zoom.steer(to: 0)
            // Lets the zoom's timeline stop drawing once the glide has settled.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.1))
                self?.objectWillChange.send()
            }
        } else {
            zoom.steer(to: 1)
            if let r = remaining {
                remaining = nil
                startAdvance(after: r)
            }
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
        zoom.steer(to: 0)
        Theme.haptic(.levelChange)
        withAnimation(.easeOut(duration: 0.35)) { boostDone = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            self?.onBoostDone?()
        }
    }

    func stop() { advanceTask?.cancel(); watchdogTask?.cancel(); loadTask?.cancel(); boostTask?.cancel(); toastTask?.cancel() }
}

// MARK: - Media

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
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private let seamLayer = CALayer()
    private let output: AVPlayerItemVideoOutput?
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var timeObserver: Any?
    private var volumeRamp: Timer?
    private var startedAt: Date?
    private var paused: Bool
    private var muted: Bool
    private let onReady: () -> Void
    private let onEnd: () -> Void
    private let onFail: () -> Void
    private let onProgress: (Double) -> Void

    init(url: URL, paused: Bool, muted: Bool, onReady: @escaping () -> Void, onEnd: @escaping () -> Void,
         onFail: @escaping () -> Void, onProgress: @escaping (Double) -> Void) {
        player = MainActor.assumeIsolated { VideoPool.shared.take(url) }
        output = player.currentItem?.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.first
        self.paused = paused
        self.muted = muted
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
        player.isMuted = muted
        player.volume = muted ? 1 : 0
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
            statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
                let s = it.status
                Task { @MainActor in
                    if s == .failed { self?.onFail() }
                    else if s == .readyToPlay, let self, self.startedAt == nil { self.startedAt = Date(); self.onReady() }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.onProgress(min(1, t.seconds / d))
            }
        }
        if !paused { player.play() }
        if !muted { rampVolume(to: 1, over: 0.4) }
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
        guard let output, let buf = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else { return }
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

    /// Sound never cuts in or out: it fades over a fraction of a second.
    private func rampVolume(to target: Float, over d: TimeInterval = 0.3, then done: (() -> Void)? = nil) {
        volumeRamp?.invalidate()
        let p = player
        let start = p.volume
        let t0 = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { timer in
            let f = Float(min(1, Date().timeIntervalSince(t0) / d))
            p.volume = start + (target - start) * f
            if f >= 1 { timer.invalidate(); done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        volumeRamp = t
    }

    func apply(paused: Bool, muted: Bool) {
        if muted != self.muted {
            self.muted = muted
            if muted {
                rampVolume(to: 0, over: 0.2) { [weak self] in self?.player.isMuted = true }
            } else {
                player.volume = 0
                player.isMuted = false
                rampVolume(to: 1)
            }
        }
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
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        statusObs = nil
        let p = player
        let stop = { p.pause(); p.replaceCurrentItem(with: nil) }
        if !muted && p.volume > 0 { rampVolume(to: 0, over: 0.25, then: stop) } else { stop() }
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
/// The post's thumbnail shows at once, sharp, and the real media fades in over it. Stills drift slowly
/// toward the animal.
struct MediaView: View {
    let item: CuteItem
    @ObservedObject var model: PlayerModel
    @State private var image: NSImage?
    @State private var poster: NSImage?
    @State private var videoReady = false
    @State private var focus = CGPoint(x: 0.5, y: 0.45)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var zooms: Bool { !reduceMotion && !Theme.lowPower }

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
                    if item.stillURL.pathExtension.lowercased() == "gif" { AnimatedImage(image: image) } else { drifting(image) }
                }
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

    /// The slow zoom, driven by an eased clock: pausing glides it to a stop instead of freezing it mid-motion.
    private func drifting(_ img: NSImage) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !zooms || model.zoom.resting(at: Date()))) { ctx in
            let t = zooms ? min(1, model.zoom.value(at: ctx.date) / (PlayerModel.imageSeconds + 1)) : 0
            still(img).scaleEffect(1 + 0.06 * t, anchor: UnitPoint(x: focus.x, y: focus.y))
        }
    }

    private func load() async {
        if let t = item.thumb {
            poster = ImageCache.shared.cached(t)
            Task { if let l = await Looks.shared.analyze(t) { model.look(l, for: item) } }
        }
        if item.isVideo {
            if poster == nil, let t = item.thumb { poster = await ImageCache.shared.image(t) }
            return
        }
        guard let img = await ImageCache.shared.image(item.stillURL) else { model.failed(item); return }
        image = img
        model.ready(item)
        if let l = await Looks.shared.analyze(item.stillURL) {
            focus = l.focus
            if item.thumb == nil { model.look(l, for: item) }
        }
    }
}

// MARK: - Spotlight

/// Wraps an overlay card: dims and tints the screen, and flies the card out of `origin` (a notch card, or the
/// notch itself) to the center, then back into the notch on close.
@MainActor final class OverlayState: ObservableObject {
    @Published var presented = false
    @Published var origin: CGRect
    /// The notch, in the overlay's coordinates: the card closes into it and new favorites fly up to it.
    let notch: CGRect
    /// The picture on the card that was clicked; it fills the card in flight and becomes the first post.
    @Published var flightImage: NSImage?
    @Published private(set) var look: Look?
    @Published var heartFlights = 0
    var heartStart = CGPoint.zero

    init(origin: CGRect, notch: CGRect, flightImage: NSImage?) {
        self.origin = origin
        self.notch = notch
        self.flightImage = flightImage
    }

    /// Moves the backdrop to a new post's light, taking longer for a bigger change of color.
    func setLook(_ l: Look) {
        let d = look.map { l.average.distance(to: $0.average) } ?? 0.6
        withAnimation(.easeInOut(duration: 0.45 + min(1, d * 2) * 0.75)) { look = l }
    }
}

private struct GlowKey: EnvironmentKey { static let defaultValue: Look? = nil }
extension EnvironmentValues {
    /// The current post's light, for chrome that picks up a hint of it.
    var glow: Look? {
        get { self[GlowKey.self] }
        set { self[GlowKey.self] = newValue }
    }
}

/// Light from the photo's top above the card and from its bottom below it. The colors animate channel by
/// channel, so one tint flows straight into the next instead of fading through grey.
struct GlowLight: ViewModifier, Animatable {
    var top: RGB
    var bottom: RGB
    var strength: Double

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>, AnimatablePair<AnimatablePair<Double, Double>, Double>> {
        get { .init(.init(.init(top.r, top.g), .init(top.b, bottom.r)), .init(.init(bottom.g, bottom.b), strength)) }
        set {
            top = RGB(r: newValue.first.first.first, g: newValue.first.first.second, b: newValue.first.second.first)
            bottom = RGB(r: newValue.first.second.second, g: newValue.second.first.first, b: newValue.second.first.second)
            strength = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { g in
                let r = max(g.size.width, g.size.height)
                ZStack {
                    RadialGradient(colors: [top.color.opacity(0.55 * strength), top.color.opacity(0.2 * strength), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.22), startRadius: r * 0.08, endRadius: r * 0.62)
                    RadialGradient(colors: [bottom.color.opacity(0.55 * strength), bottom.color.opacity(0.2 * strength), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.8), startRadius: r * 0.08, endRadius: r * 0.62)
                }
            }
        }
    }
}

struct Presented<Content: View>: View {
    @ObservedObject var overlay: OverlayState
    let cardSize: CGSize
    let close: () -> Void
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Late at night the light is a little dimmer and warmer.
    private var shownLook: Look? {
        guard var l = overlay.look else { return nil }
        if Theme.lateNight {
            let ember = RGB(r: 1, g: 0.62, b: 0.36)
            l.top = l.top.mixed(with: ember, 0.2).scaled(0.85)
            l.bottom = l.bottom.mixed(with: ember, 0.2).scaled(0.85)
        }
        return l
    }

    var body: some View {
        GeometryReader { g in
            let p = overlay.presented
            let o = overlay.origin
            let s = reduceMotion ? 1 : max(0.04, o.width / cardSize.width)
            let dx = reduceMotion ? 0 : o.midX - g.size.width / 2
            let dy = reduceMotion ? 0 : o.midY - g.size.height / 2
            let look = shownLook
            let edge = (look?.average ?? RGB.neutral).color
            ZStack {
                backdrop(look)
                    .mask { spread(g.size, from: o, open: p) }
                    .opacity(p ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                content
                    .opacity(p || overlay.flightImage != nil ? 1 : 0)
                    .animation(p ? .easeOut(duration: 0.3) : .easeIn(duration: 0.34), value: p)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .overlay {
                        if let f = overlay.flightImage {
                            Image(nsImage: f).resizable().scaledToFill()
                                .frame(width: cardSize.width, height: cardSize.height).clipped()
                                .opacity(p ? 0 : 1)
                                .animation(p ? .easeIn(duration: 0.4).delay(0.12) : .easeOut(duration: 0.2), value: p)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Color(white: 0.07))
                    .clipShape(RoundedRectangle(cornerRadius: p ? Theme.playerRadius : min(Theme.cardRadius / s, cardSize.height / 2), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.playerRadius, style: .continuous)
                        .strokeBorder(edge.opacity(p ? 0.32 : 0), lineWidth: 1))
                    .shadow(color: edge.opacity(p ? 0.3 : 0), radius: 60)
                    .shadow(color: .black.opacity(p ? 0.5 : 0), radius: 40, y: 14)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .scaleEffect(p ? 1 : s)
                    .offset(x: p ? 0 : dx, y: p ? 0 : dy)
                if overlay.heartFlights > 0 {
                    HeartFlight(from: overlay.heartStart, to: CGPoint(x: overlay.notch.midX, y: overlay.notch.maxY - 4))
                        .id(overlay.heartFlights)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .environment(\.glow, shownLook)
    }

    private func backdrop(_ look: Look?) -> some View {
        Color.black.opacity((reduceTransparency ? 0.94 : 0.8) + (Theme.lateNight ? 0.06 : 0))
            .modifier(GlowLight(top: look?.top ?? .neutral, bottom: look?.bottom ?? .neutral, strength: look == nil ? 0 : 1))
    }

    /// The dimming spreads outward from where the card came from, and draws back into the notch on close.
    @ViewBuilder private func spread(_ size: CGSize, from o: CGRect, open p: Bool) -> some View {
        if reduceMotion {
            Color.black
        } else {
            let d = 2.4 * (size.width * size.width + size.height * size.height).squareRoot()
            Circle()
                .frame(width: d, height: d)
                .position(x: o.midX, y: o.midY)
                .scaleEffect(p ? 1 : 0.001, anchor: UnitPoint(x: o.midX / max(size.width, 1), y: o.midY / max(size.height, 1)))
                .blur(radius: 90)
        }
    }
}

/// A new favorite's heart, flying from the button up into the notch, where favorites live.
struct HeartFlight: View {
    let from: CGPoint
    let to: CGPoint
    @State private var go = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(Theme.pink)
            .shadow(color: Theme.pink.opacity(0.7), radius: 6)
            .opacity(go ? 0 : 1)
            .animation(.easeIn(duration: 0.2).delay(0.58), value: go)
            .scaleEffect(go ? 0.5 : 1.1)
            .position(go ? to : from)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: 0.8)) { go = true } }
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
    @State private var bigHeart = 0
    @State private var bigHeartAt = CGPoint.zero
    @Environment(\.glow) private var glow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Title, credit and controls step back after a couple of quiet seconds and return on any mouse move.
    private var chromeShown: Bool { chrome || overControls || model.paused || model.current == nil || model.boostDone }

    var body: some View {
        ZStack {
            mediaLayer
            scrims
            favoriteMark
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

    /// Click to pause; double-click to favorite, with the heart where you clicked. Posts drift in from the side
    /// you're heading, and follow your fingers during a swipe.
    private var mediaLayer: some View {
        let dir = CGFloat(model.direction)
        let drift: AnyTransition = reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 16 * dir)),
            removal: .opacity.combined(with: .offset(x: -16 * dir)))
        return ZStack {
            if let item = model.current {
                MediaView(item: item, model: model)
                    .id(item.url)
                    .offset(x: model.drag)
                    .transition(drift)
            } else {
                placeholder.transition(.opacity)
            }
            if bigHeart > 0 { BigHeart().id(bigHeart).position(bigHeartAt) }
        }
        .animation(Theme.fade, value: model.current?.url)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(count: 2).onEnded { v in
                guard model.current != nil else { return }
                model.favoriteFromDoubleClick()
                bigHeartAt = v.location
                bigHeart += 1
            }
            .exclusively(before: TapGesture().onEnded { if model.current != nil { model.togglePause() } })
        )
    }

    /// The shading behind the title follows the photo: stronger over a bright bottom edge, faint over a dark one.
    private var scrims: some View {
        let bottomShade = 0.5 + 0.35 * (glow?.bottomLuma ?? 0.4)
        return VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .opacity(chromeShown || model.boostLength != nil ? 1 : 0)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(bottomShade)], startPoint: .top, endPoint: .bottom)
                .frame(height: 190)
                .opacity(chromeShown ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    /// While the controls are tucked away, a tiny heart marks a post you've already favorited.
    @ViewBuilder private var favoriteMark: some View {
        if let item = model.current, favorites.contains(item), !chromeShown {
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.pink)
                .shadow(color: .black.opacity(0.4), radius: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(20)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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

    /// The Focus Boost bar breathes once over its last three seconds.
    @ViewBuilder private var progressRow: some View {
        if let len = model.boostLength {
            let left = model.boostLeft
            let breathe = left > 0 && left < 3 ? sin((3 - left) / 3 * .pi) : 0
            HStack(spacing: 10) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 4 + 2.5 * breathe)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Theme.pink).frame(width: g.size.width * (1 - left / len))
                                .shadow(color: Theme.pink.opacity(0.7 * breathe), radius: 6)
                        }
                    }
                    .animation(.linear(duration: 0.1), value: left)
                Text(clock(left)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().opacity(0.85)
            }
            .frame(height: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Focus Boost, \(Int(left.rounded(.up))) seconds left")
        } else {
            StorySegments(model: model, paused: !chromeShown)
                .accessibilityHidden(true)
        }
    }

    private var bottomRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if let item = model.current {
                VStack(alignment: .leading, spacing: 5) {
                    FadingTitle(text: item.title)
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
                .background(GeometryReader { g in
                    let f = g.frame(in: .global)
                    Color.clear
                        .onAppear { model.heartPoint = CGPoint(x: f.midX, y: f.midY) }
                        .onChange(of: f) { _, n in model.heartPoint = CGPoint(x: n.midX, y: n.midY) }
                })
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

    /// One of a few warm lines, and where you're headed back to.
    private var doneOverlay: some View {
        VStack(spacing: 8) {
            Text("✨").font(.system(size: 52))
            Text(model.ending.title).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(model.ending.line).font(.system(size: 15, design: .rounded)).opacity(0.75)
            if let app = model.returnApp, let name = app.localizedName {
                HStack(spacing: 7) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text("Back to \(name)").font(.system(size: 13, weight: .medium, design: .rounded))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(GlassCapsule())
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.62))
        .accessibilityElement(children: .combine)
    }
}

/// Up to two lines. A longer title fades out at the bottom instead of ending in "…".
struct FadingTitle: View {
    let text: String
    @State private var fullHeight: CGFloat = 0
    private let maxHeight: CGFloat = 44

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { fullHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in fullHeight = h }
            })
            .frame(maxHeight: maxHeight, alignment: .top)
            .clipped()
            .mask {
                if fullHeight > maxHeight + 1 {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 8)
    }
}

/// A short window of story-style segments around the current post; the current one fills as it plays and
/// dims while paused. The track carries a hint of the photo's light.
struct StorySegments: View {
    @ObservedObject var model: PlayerModel
    let paused: Bool
    @Environment(\.glow) private var glow

    var body: some View {
        let n = model.items.count
        let i = model.index
        let span = min(n, 7)
        let start = n <= 7 ? 0 : min(max(0, i - 2), n - span)
        let track = (glow?.average ?? RGB(r: 1, g: 1, b: 1)).mixed(with: RGB(r: 1, g: 1, b: 1), 0.6).color
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || model.paused)) { ctx in
            HStack(spacing: 4) {
                ForEach(0..<span, id: \.self) { k in
                    let idx = start + k
                    let f: Double = idx < i ? 1 : idx > i ? 0 : model.progress(at: ctx.date)
                    Capsule().fill(track.opacity(0.3))
                        .overlay(alignment: .leading) {
                            GeometryReader { g in
                                Capsule().fill(Color.white.opacity(idx == i && model.paused ? 0.55 : 1)).frame(width: g.size.width * f)
                            }
                        }
                }
            }
        }
        .frame(height: 3)
        .animation(.easeInOut(duration: 0.3), value: model.paused)
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

/// Glass, with about a tenth of the current photo's light in it.
struct GlassCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glow) private var glow

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if reduceTransparency { Capsule().fill(Color.black.opacity(0.85)) } else { Capsule().fill(.ultraThinMaterial) }
                if let glow { Capsule().fill(glow.average.color.opacity(0.1)) }
            }
        }
    }
}

struct HeartBurst: View {
    var radius: CGFloat = 30
    var size: CGFloat = 8
    @State private var fly = false

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let a = Double(i) / 7 * 2 * .pi - .pi / 2
                Image(systemName: "heart.fill")
                    .font(.system(size: size + CGFloat(i % 3) * size / 4))
                    .foregroundColor(Theme.pink)
                    .offset(x: fly ? cos(a) * radius : 0, y: fly ? sin(a) * radius : 0)
                    .scaleEffect(fly ? 0.5 : 1)
                    .opacity(fly ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.65)) { fly = true } }
    }
}

/// The double-click heart: pops up where you clicked, with a ring of small hearts, then fades.
struct BigHeart: View {
    @State private var phase = 0

    var body: some View {
        ZStack {
            HeartBurst(radius: 80, size: 14)
            Image(systemName: "heart.fill")
                .font(.system(size: 72))
                .foregroundColor(Theme.pink)
                .shadow(color: .black.opacity(0.3), radius: 12)
                .scaleEffect(phase == 0 ? 0.2 : phase == 1 ? 1.15 : 1)
                .opacity(phase == 2 ? 0 : 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { phase = 1 }
            Task {
                try? await Task.sleep(for: .seconds(0.55))
                withAnimation(.easeIn(duration: 0.3)) { phase = 2 }
            }
        }
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
/// reminder, the eyes peeking out on their own. open: the gallery. glow: the notch swelling as it takes the
/// card back (pink after a Focus Boost).
enum NotchPhase { case hidden, peek, nudge, open, glow }

/// What a card shows: a picture, the post it came from, and where the animal is in it.
struct CardArt {
    var image: NSImage
    var item: CuteItem
    var focus: CGPoint
}

@MainActor final class NotchState: ObservableObject {
    @Published var phase = NotchPhase.hidden
    @Published var art: [String: CardArt] = [:]
    /// A second post per card, shown when you rest on it.
    @Published var altArt: [String: CardArt] = [:]
    @Published var favoriteArt: [CardArt] = []
    @Published var notchSize = CGSize(width: 180, height: 0)
    @Published var panelSize = CGSize(width: 700, height: 200)
    @Published var notchHeight: CGFloat = 32
    @Published var dwell = Theme.dwell
    /// Where the pointer sits across the notch, -1 (left) to 1 (right), for the eyes to follow.
    @Published var gaze: CGFloat = 0
    /// The card chosen with the keyboard.
    @Published var selected: String?
    /// The eyes smile for a moment as the panel unfolds.
    @Published var smiling = false
    @Published var glowPink = false
}

/// The panel's cards in order: Focus Boost, the categories, then Favorites once there are any.
@MainActor func panelCards() -> [CuteCategory] {
    [boostCategory] + categories + (Favorites.shared.items.isEmpty ? [] : [favoritesCategory])
}

let cardWidth: CGFloat = 96
let cardSpacing: CGFloat = 10

/// An image filling its frame, cropped around `focus` (unit point, top-left origin) instead of the center.
struct FocusedFill: View {
    let image: NSImage
    let focus: CGPoint

    var body: some View {
        GeometryReader { g in
            let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
            let scale = max(g.size.width / iw, g.size.height / ih)
            let w = iw * scale, h = ih * scale
            let x = min(0, max(g.size.width - w, g.size.width / 2 - focus.x * w))
            let y = min(0, max(g.size.height - h, g.size.height / 2 - focus.y * h))
            Image(nsImage: image).resizable().interpolation(.high).frame(width: w, height: h).offset(x: x, y: y)
        }
        .clipped()
    }
}

struct NotchGalleryView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var favorites = Favorites.shared
    let onPick: (CuteCategory, CGRect?, CardArt?) -> Void
    let onAbout: () -> Void
    @State private var hovered: String?
    @State private var tilt = CGPoint.zero
    @State private var living: String?
    @State private var aboutHovered = false
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var open: Bool { state.phase == .open }
    private var peekSize: CGSize { CGSize(width: state.notchSize.width + 28, height: state.notchSize.height + 18) }

    /// One black shape that is the notch, grows a little while you hover, and unfolds into the gallery.
    var body: some View {
        let size = shapeSize
        let r: CGFloat = open ? 28 : 10
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        ZStack(alignment: .top) {
            content.frame(width: state.panelSize.width, height: state.panelSize.height, alignment: .top)
            if state.phase == .peek || state.phase == .nudge || state.smiling {
                PeekFace(dwell: state.dwell, nudge: state.phase == .nudge, gaze: state.gaze, smiling: state.smiling)
                    .id(state.phase == .nudge)
                    .frame(width: peekSize.width, height: peekSize.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(shape)
        .background(shape.fill(Color.black).shadow(color: Theme.pink.opacity(state.phase == .glow && state.glowPink ? 0.95 : 0),
                                                   radius: state.phase == .glow && state.glowPink ? 18 : 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var shapeSize: CGSize {
        let n = state.notchSize
        switch state.phase {
        case .open: return state.panelSize
        case .peek, .nudge: return peekSize
        case .glow: return CGSize(width: n.width + 10, height: max(n.height, 6) + 4)
        case .hidden: return n
        }
    }

    private var content: some View {
        let cards = panelCards()
        return VStack(spacing: 0) {
            Spacer().frame(height: state.notchHeight)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                        card(c)
                            .opacity(open ? 1 : 0)
                            .offset(y: open || reduceMotion ? 0 : -14)
                            .scaleEffect(open || reduceMotion ? 1 : 0.9, anchor: .top)
                            // In one after another; out in reverse, last card first.
                            .animation(open
                                       ? (reduceMotion ? .easeOut(duration: 0.15) : Theme.open.delay(0.05 + Double(i) * 0.035))
                                       : .easeIn(duration: 0.12).delay(Double(cards.count - 1 - i) * 0.022), value: open)
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

    /// The art a card is showing right now: its second post while you rest on it.
    private func shownArt(_ c: CuteCategory) -> CardArt? {
        if living == c.id, let alt = state.altArt[c.id] { return alt }
        return state.art[c.id]
    }

    private func card(_ c: CuteCategory) -> some View {
        let isHovered = hovered == c.id
        let lit = isHovered || state.selected == c.id
        let accent = c.id == boostCategory.id
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        let t = isHovered && !reduceMotion ? tilt : .zero
        let art = shownArt(c)
        return ZStack(alignment: .bottomLeading) {
            if accent {
                LinearGradient(colors: [Theme.pink, Theme.pinkDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color.white.opacity(lit ? 0.2 : 0.08)
            }
            if c.id == favoritesCategory.id, !state.favoriteArt.isEmpty {
                FavoriteStack(art: state.favoriteArt, fanned: lit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: -t.x * 3, y: -14 - t.y * 3)
                cornerLabel(c)
            } else if !accent, let art {
                FocusedFill(image: art.image, focus: art.focus)
                    .frame(width: cardWidth + 8, height: 120)
                    .offset(x: -t.x * 4, y: -t.y * 4)
                    .scaleEffect(lit ? 1.06 : 1)
                    .id(art.item.url)
                    .transition(.opacity)
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
        .animation(.easeInOut(duration: 0.6), value: art?.item.url)
        .foregroundColor(.white)
        .frame(width: cardWidth, height: 112)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(isHovered ? 0.55 : 0), lineWidth: 1.5))
        .overlay {
            if state.selected == c.id {
                shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 2).matchedGeometryEffect(id: "ring", in: ring)
            }
        }
        .overlay(GeometryReader { g in
            Color.clear.contentShape(Rectangle()).onTapGesture { onPick(c, g.frame(in: .global), shownArt(c)) }
        })
        .rotation3DEffect(.degrees(Double(t.y) * -7), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(Double(t.x) * 7), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: 10, y: 6)
        .scaleEffect(lit ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lit)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                // Tilts toward the pointer, as if the card were resting on a fingertip.
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                    tilt = CGPoint(x: (p.x / cardWidth) * 2 - 1, y: (p.y / 112) * 2 - 1)
                }
            case .ended:
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { tilt = .zero }
            }
        }
        .onHover { h in
            if h {
                hovered = c.id
                Theme.haptic(.alignment)
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if hovered == c.id, state.altArt[c.id] != nil { living = c.id }
                }
            } else if hovered == c.id {
                hovered = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.name + (sub(for: c).map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPick(c, nil, shownArt(c)) }
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

/// Up to three saved posts, fanned like photos on a table, the first in front. They spread a little on hover.
struct FavoriteStack: View {
    let art: [CardArt]
    let fanned: Bool

    var body: some View {
        let n = min(art.count, 3)
        // Draw the sides first so the first picture sits on top in the middle.
        let slots: [(index: Int, pos: Double)] = n == 3 ? [(1, -1), (2, 1), (0, 0)] : n == 2 ? [(1, -0.5), (0, 0.5)] : [(0, 0)]
        ZStack {
            ForEach(0..<slots.count, id: \.self) { k in
                let s = slots[k]
                FocusedFill(image: art[s.index].image, focus: art[s.index].focus)
                    .frame(width: 46, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .rotationEffect(.degrees(s.pos * (fanned ? 13 : 8)))
                    .offset(x: s.pos * (fanned ? 17 : 11), y: abs(s.pos) * 3)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: fanned)
    }
}

/// Two eyes and a filling line under the notch while the pointer rests there: it noticed you, and it's opening.
/// The eyes follow the pointer, blink at slightly random moments, and smile as the panel unfolds. As a break
/// reminder (`nudge`) they just peek out and blink, with no line.
struct PeekFace: View {
    let dwell: TimeInterval
    let nudge: Bool
    let gaze: CGFloat
    let smiling: Bool
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
            .opacity(nudge || smiling ? 0 : 1)
        }
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { shown = true }
            if !nudge { withAnimation(.linear(duration: dwell)) { fill = true } }
            guard !reduceMotion else { return }
            let waits = nudge
                ? [Double.random(in: 0.5...0.9), Double.random(in: 0.8...1.3), 0.18]
                : [min(dwell, Theme.dwell) * Double.random(in: 0.35...0.65)]
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
        ZStack {
            Capsule().fill(Color.white)
                .frame(width: 6, height: blink ? 1.5 : 6)
                .opacity(smiling ? 0 : 1)
            SmileArc()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 7, height: 4)
                .opacity(smiling ? 1 : 0)
        }
        .scaleEffect(shown ? 1 : 0.2)
        .opacity(shown ? 1 : 0)
    }
}

/// A happy, upturned eye: ∩.
struct SmileArc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        return p
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
/// Only while opened from the keyboard: a panel that can become key spends the first mouse click on becoming key,
/// so a clicked card wouldn't open until the second click.
final class KeyPanel: NSPanel {
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
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
    private var swipeSpeed: CGFloat = 0
    private var wheelReadyAt = Date.distantPast
    private let state = NotchState()
    /// Remaining Focus Boost time for the menu bar, or nil when none is running.
    var statusTick: ((TimeInterval?) -> Void)?

    private var panelOpen: Bool { state.phase == .open }

    /// Mouse-move events wake the hover check; the 20 Hz timer only runs while a hover or the panel is in progress.
    func start() {
        _ = NetworkState.shared
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
                onPick: { [weak self] c, r, art in self?.pick(c, from: r, art: art) },
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
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { state.phase = .hidden }
        orderOutPanel(after: 0.3)
    }

    private func openPanel(on screen: NSScreen) {
        if state.phase != .peek {
            preparePanel(on: screen)
            panel?.orderFrontRegardless()
        }
        hoverStart = nil
        leaveStart = nil
        panel?.ignoresMouseEvents = false
        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { state.smiling = true }
        withAnimation(Theme.reduceMotion ? .easeOut(duration: 0.15) : Theme.open) { state.phase = .open }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.35))
            withAnimation(.easeOut(duration: 0.25)) { self?.state.smiling = false }
        }
        // Only fills in cards that have nothing yet; the rest refresh after the panel closes, never while you look.
        if state.art.count < categories.count { refreshThumbs(onlyMissing: true) }
        warm()
    }

    private func hidePanel() {
        guard panelOpen else { return }
        if let k = panelKeyMonitor { NSEvent.removeMonitor(k); panelKeyMonitor = nil }
        keyboardPanel = false
        panel?.acceptsKeyboard = false
        state.selected = nil
        leaveStart = nil
        hoverStart = nil
        panel?.ignoresMouseEvents = true
        // The cards fold away first (each animates itself), then the shape follows them into the notch.
        withAnimation(Theme.reduceMotion ? .easeIn(duration: 0.12) : Theme.settle.delay(0.1)) { state.phase = .hidden }
        orderOutPanel(after: 0.5)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard let self, self.state.phase == .hidden else { return }
            self.refreshThumbs(onlyMissing: false)
        }
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
        panel?.acceptsKeyboard = true
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
        let glide = Animation.spring(response: 0.3, dampingFraction: 0.82)
        switch code {
        case 123: withAnimation(glide) { state.selected = cards[max(0, i - 1)].id }
        case 124: withAnimation(glide) { state.selected = cards[min(cards.count - 1, i + 1)].id }
        case 36, 76: pick(cards[i], from: nil, art: state.art[cards[i].id])
        case 53: hidePanel()
        default:
            guard let n = digits.firstIndex(of: code), n < cards.count else { return false }
            pick(cards[n], from: nil, art: state.art[cards[n].id])
        }
        return true
    }

    /// The notch swells for a moment as it takes the card back; after a Focus Boost it glows pink as well.
    private func bumpNotch(pink: Bool) {
        guard let screen = notchScreen(), state.phase == .hidden else { return }
        preparePanel(on: screen)
        state.glowPink = pink
        panel?.ignoresMouseEvents = true
        panel?.orderFrontRegardless()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { state.phase = .glow }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(pink ? 0.9 : 0.2))
            guard let self, self.state.phase == .glow else { return }
            withAnimation(pink ? .easeIn(duration: 0.6) : .spring(response: 0.3, dampingFraction: 0.8)) { self.state.phase = .hidden }
            self.orderOutPanel(after: pink ? 0.65 : 0.35)
        }
    }

    private func orderOutPanel(after secs: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            guard let self, self.state.phase == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func pick(_ c: CuteCategory, from r: CGRect?, art: CardArt?) {
        Theme.haptic()
        let origin = r.flatMap { r in panel.map { NSRect(x: $0.frame.minX + r.minX, y: $0.frame.maxY - r.maxY, width: r.width, height: r.height) } }
        if c.id == boostCategory.id { openBoost(from: origin) } else { openSpotlight(c, from: origin, art: art) }
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

    // MARK: Background feeds and card art

    /// Refreshes feeds older than an hour, one at a time, so categories open instantly from disk.
    /// Runs at launch and whenever the panel opens; gives way to anything the user is waiting on,
    /// and sits out Low Power Mode.
    private func warm() {
        guard warmTask == nil, !Theme.lowPower else { return }
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
                if c.id != boostCategory.id, self?.state.art[c.id] == nil, self?.panelOpen == false { await self?.refreshArt(c) }
            }
            self?.warmTask = nil
        }
    }

    private func refreshThumbs(onlyMissing: Bool) {
        Task { [weak self] in
            for c in categories {
                if onlyMissing && self?.state.art[c.id] != nil { continue }
                await self?.refreshArt(c)
            }
            if !onlyMissing || self?.state.favoriteArt.isEmpty == true { await self?.refreshFavoriteStack() }
        }
    }

    private func cardArt(_ post: CuteItem) async -> CardArt? {
        guard let u = post.thumb, let img = await ImageCache.shared.image(u) else { return nil }
        let focus = await Looks.shared.analyze(u)?.focus ?? CGPoint(x: 0.5, y: 0.45)
        return CardArt(image: img, item: post, focus: focus)
    }

    /// Each card shows a post you haven't seen yet when there is one, framed on the animal, plus a second one
    /// for when you rest on it.
    private func refreshArt(_ c: CuteCategory) async {
        let items = await FeedStore.shared.cached(c).items.filter { $0.thumb != nil }
        let unseen = items.filter { !Seen.contains($0.url) }
        let picks = Array((unseen.count >= 2 ? unseen : items).shuffled().prefix(2))
        guard let first = picks.first, let a = await cardArt(first) else { return }
        let b = picks.count > 1 ? await cardArt(picks[1]) : nil
        state.art[c.id] = a
        state.altArt[c.id] = b
    }

    private func refreshFavoriteStack() async {
        var out: [CardArt] = []
        for post in Favorites.shared.items.filter({ $0.thumb != nil }).shuffled() where out.count < 3 {
            if let a = await cardArt(post) { out.append(a) }
        }
        state.favoriteArt = out
        if let first = out.first { state.art[favoritesCategory.id] = first }
    }

    // MARK: Overlays

    func openSpotlight(_ c: CuteCategory, from origin: NSRect? = nil, art: CardArt? = nil) {
        openPlayer(PlayerModel(category: c, lead: art?.item), from: origin, flightImage: art?.image)
    }

    func openBoost(from origin: NSRect? = nil) {
        openPlayer(PlayerModel(category: boostCategory, boostLength: Prefs.boostSeconds), from: origin, flightImage: nil)
    }

    private func openPlayer(_ m: PlayerModel, from origin: NSRect?, flightImage: NSImage?) {
        activeMinutes = 0
        m.onBoostDone = { [weak self, weak m] in
            guard let self, let m, self.model === m else { return }
            self.closeSpotlight(glow: true)
        }
        m.onBoostTick = { [weak self] left in self?.statusTick?(left) }
        let ov = presentOverlay(from: origin, flightImage: flightImage, maxSize: CGSize(width: 880, height: 680), content: { [weak self] _ in
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
        m.returnApp = previousApp
        m.onLook = { [weak ov] l in ov?.setLook(l) }
        m.onFavorited = { [weak ov, weak m] in
            guard let ov, let m else { return }
            ov.heartStart = m.heartPoint
            ov.heartFlights += 1
        }
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.scroll(e) }
            return e
        }) { overlayMonitors.append(s) }
        model = m
        m.load()
    }

    /// Two fingers drag the current post (it follows, with a little resistance); let go past a threshold or with
    /// a flick to move on, otherwise it springs back. A mouse wheel moves one post per notch.
    private func scroll(_ e: NSEvent) {
        guard let m = model else { return }
        if !e.hasPreciseScrollingDeltas {
            let d = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX
            guard abs(d) > 0.3, Date() > wheelReadyAt else { return }
            wheelReadyAt = Date().addingTimeInterval(0.35)
            let wheelDown = e.isDirectionInvertedFromDevice ? d > 0 : d < 0
            if wheelDown { m.next() } else { m.prev() }
            return
        }
        if !e.momentumPhase.isEmpty { return }
        switch e.phase {
        case .began:
            swipeTravel = 0
            swipeSpeed = 0
        case .changed:
            guard swipeTravel != 0 || abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
            let fingers = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            swipeTravel += fingers
            swipeSpeed = fingers
            m.drag = swipeTravel / (1 + abs(swipeTravel) / 320)
        case .ended, .cancelled:
            let commit = e.phase == .ended && (abs(swipeTravel) > 90 || (abs(swipeSpeed) > 18 && abs(swipeTravel) > 30))
            if commit {
                Theme.haptic(.alignment)
                let forward = swipeTravel < 0
                withAnimation(Theme.fade) {
                    m.drag = 0
                    if forward { m.next() } else { m.prev() }
                }
            } else if swipeTravel != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { m.drag = 0 }
            }
            swipeTravel = 0
        default:
            break
        }
    }

    func openResearch() {
        presentOverlay(from: nil, flightImage: nil, maxSize: CGSize(width: 640, height: 640), content: { [weak self] _ in
            ResearchView(close: { self?.closeSpotlight() })
        }, keys: { [weak self] code, _ in
            guard code == 53 else { return false }
            self?.closeSpotlight()
            return true
        })
    }

    @discardableResult
    private func presentOverlay<V: View>(from origin: NSRect?, flightImage: NSImage?, maxSize: CGSize, content: (CGSize) -> V,
                                         keys: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool) -> OverlayState? {
        hidePanel()
        if spotlight != nil { closeSpotlight() }
        guard let screen = overlayScreen() else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previousApp = front }
        let size = CGSize(width: min(maxSize.width, screen.frame.width - 80), height: min(maxSize.height, screen.frame.height - 120))
        let notch = local(notchRect(screen), in: screen)
        let ov = OverlayState(origin: origin.map { local($0, in: screen) } ?? notch, notch: notch, flightImage: flightImage)
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

    /// Shrinks the card back into the notch (springs retarget, so this smoothly reverses a card still flying out),
    /// and the notch swells as it arrives, glowing pink after a finished Focus Boost. When a share was chosen,
    /// NotchCute stays in front so the share sheet can appear. Afterwards the picture cache is cleared.
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
        ov.flightImage = nil
        ov.origin = ov.notch
        withAnimation(Theme.reduceMotion ? .easeIn(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.9)) { ov.presented = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.bumpNotch(pink: glow)
            try? await Task.sleep(for: .milliseconds(100))
            w.contentView = nil
            w.orderOut(nil)
            if self?.spotlight == nil {
                var keep: [URL: NSImage] = [:]
                if let st = self?.state {
                    for art in Array(st.art.values) + Array(st.altArt.values) + st.favoriteArt {
                        if let u = art.item.thumb { keep[u] = art.image }
                    }
                }
                ImageCache.shared.purge(keeping: keep)
                VideoPool.shared.clear()
            }
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
