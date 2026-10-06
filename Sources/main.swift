// NotchCute: hover the MacBook notch, pick a cute category, watch cute things.
import AppKit
import SwiftUI
import AVFoundation

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

let userAgent = "macos:com.chrisdimarco.notchcute:v0.1 (open source; github.com/ChrisJDiMarco/NotchCute)"

// MARK: - Feed

struct CuteItem: Hashable {
    let title: String
    let url: URL
    let isVideo: Bool
    let subreddit: String
}

func fetchData(_ url: URL) async throws -> Data {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
}

final class AtomParser: NSObject, XMLParserDelegate {
    struct Entry { var title = ""; var content = "" }
    var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "entry" { current = Entry() }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if current != nil {
            if elementName == "title" { current!.title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else if elementName == "content" { current!.content = text }
            else if elementName == "entry" { entries.append(current!); current = nil }
        }
        text = ""
    }
}

let sadWords = ["rip ", "r.i.p", "passed away", "rainbow bridge", "put down", "euthan", "nsfw", "nsfl", "cancer", "died", "in memory"]

func mediaItem(title: String, html: String, sub: String) -> CuteItem? {
    let lower = title.lowercased() + " "
    if sadWords.contains(where: { lower.contains($0) }) { return nil }
    guard let r = html.range(of: #"href="([^"]+)">\[link\]"#, options: .regularExpression) else { return nil }
    let raw = String(html[r])
        .replacingOccurrences(of: "href=\"", with: "")
        .replacingOccurrences(of: "\">[link]", with: "")
        .replacingOccurrences(of: "&amp;", with: "&")
    guard let u = URL(string: raw), let host = u.host?.lowercased() else { return nil }
    let ext = u.pathExtension.lowercased()
    if host == "v.redd.it" {
        return CuteItem(title: title, url: u.appendingPathComponent("HLSPlaylist.m3u8"), isVideo: true, subreddit: sub)
    }
    if host.hasSuffix("imgur.com") && (ext == "gifv" || ext == "mp4") {
        return CuteItem(title: title, url: u.deletingPathExtension().appendingPathExtension("mp4"), isVideo: true, subreddit: sub)
    }
    if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
        return CuteItem(title: title, url: u, isVideo: false, subreddit: sub)
    }
    return nil
}

func parseFeed(_ data: Data, sub: String) -> [CuteItem] {
    let p = AtomParser()
    let x = XMLParser(data: data)
    x.delegate = p
    x.parse()
    return p.entries.compactMap { mediaItem(title: $0.title, html: $0.content, sub: sub) }
}

/// Spaces Reddit requests 2.5 s apart, caches 15 min in memory, and falls back to the last good copy on disk.
actor FeedStore {
    static let shared = FeedStore()
    private var memory: [String: (Date, [CuteItem])] = [:]
    private var nextSlot = Date.distantPast
    private let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchCute", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func items(for sub: String) async -> [CuteItem] {
        if let m = memory[sub], Date().timeIntervalSince(m.0) < 900 { return m.1 }
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(2.5)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        let file = cacheDir.appendingPathComponent("\(sub).xml")
        var data: Data? = nil
        if let url = URL(string: "https://www.reddit.com/r/\(sub)/hot/.rss?limit=50") { data = try? await fetchData(url) }
        if let d = data { try? d.write(to: file) } else { data = try? Data(contentsOf: file) }
        guard let d = data else { return [] }
        let items = parseFeed(d, sub: sub)
        if !items.isEmpty { memory[sub] = (Date(), items) }
        return items
    }
}

// MARK: - Player model

@MainActor final class PlayerModel: ObservableObject {
    let category: CuteCategory
    @Published private(set) var items: [CuteItem] = []
    @Published private(set) var index = 0
    @Published var status = "Fetching cute things…"
    private var advanceTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init(category: CuteCategory) { self.category = category }

    var current: CuteItem? { items.indices.contains(index) ? items[index] : nil }

    func load() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            for sub in self.category.subreddits {
                let got = await FeedStore.shared.items(for: sub)
                if Task.isCancelled { return }
                let known = Set(self.items.map { $0.url })
                let fresh = got.filter { !known.contains($0.url) }.shuffled()
                if self.items.isEmpty {
                    self.items = fresh
                    self.index = 0
                    if !fresh.isEmpty { self.schedule() }
                } else {
                    for it in fresh {
                        let pos = Int.random(in: min(self.index + 1, self.items.count)...self.items.count)
                        self.items.insert(it, at: pos)
                    }
                }
            }
            if self.items.isEmpty { self.status = "Reddit didn't send anything just now. Close and try again in a minute." }
        }
    }

    func next() {
        guard !items.isEmpty else { return }
        index = (index + 1) % items.count
        schedule()
    }

    func prev() {
        guard !items.isEmpty else { return }
        index = (index - 1 + items.count) % items.count
        schedule()
    }

    func ended(_ item: CuteItem) { if current == item { next() } }

    func failed(_ item: CuteItem) {
        guard let i = items.firstIndex(of: item) else { return }
        items.remove(at: i)
        if items.isEmpty { index = 0; status = "Couldn't load anything from this category right now."; return }
        if i < index { index -= 1 }
        else if i == index { if index >= items.count { index = 0 }; schedule() }
    }

    private func schedule() {
        advanceTask?.cancel()
        guard let item = current else { return }
        let secs: Double = item.isVideo ? 45 : 8
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            if Task.isCancelled { return }
            self?.next()
        }
    }

    func stop() { advanceTask?.cancel(); loadTask?.cancel() }
}

// MARK: - Media views

struct ImageMedia: NSViewRepresentable {
    let url: URL
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
        let onFail = self.onFail
        Task { @MainActor in
            if let d = try? await fetchData(url), let img = NSImage(data: d) { v.image = img } else { onFail() }
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
    private let onEnd: () -> Void
    private let onFail: () -> Void

    init(url: URL, onEnd: @escaping () -> Void, onFail: @escaping () -> Void) {
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
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd() }
        }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            if it.status == .failed { Task { @MainActor in self?.onFail() } }
        }
        player.play()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
    let onEnd: () -> Void
    let onFail: () -> Void
    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView(url: url, onEnd: onEnd, onFail: onFail) }
    func updateNSView(_ nsView: PlayerNSView, context: Context) {}
    static func dismantleNSView(_ nsView: PlayerNSView, coordinator: ()) { nsView.teardown() }
}

// MARK: - Spotlight (dimmed screen + centered player)

struct SpotlightView: View {
    @ObservedObject var model: PlayerModel
    let cardSize: CGSize
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("\(model.category.emoji)  \(model.category.name)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    if let item = model.current {
                        Text("r/\(item.subreddit)").font(.system(size: 13, design: .rounded)).opacity(0.6)
                    }
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain)
                }
                .padding(16)

                ZStack {
                    Color.black
                    if let item = model.current {
                        Group {
                            if item.isVideo {
                                VideoMedia(url: item.url, onEnd: { model.ended(item) }, onFail: { model.failed(item) })
                            } else {
                                ImageMedia(url: item.url, onFail: { model.failed(item) })
                            }
                        }
                        .id(item.url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text(model.status).font(.system(size: 14, design: .rounded)).opacity(0.8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 14) {
                    Text(model.current?.title ?? " ")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .lineLimit(2)
                    Spacer()
                    Button(action: { model.prev() }) { Image(systemName: "chevron.left.circle.fill").font(.system(size: 26)) }
                        .buttonStyle(.plain)
                    Button(action: { model.next() }) { Image(systemName: "chevron.right.circle.fill").font(.system(size: 26)) }
                        .buttonStyle(.plain)
                }
                .padding(16)
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
}

// MARK: - Research modal

struct ResearchView: View {
    let cardSize: CGSize
    let close: () -> Void
    private let pink = Color(red: 1.0, green: 0.62, blue: 0.72)

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
                        Text("A quick look helps most before detail work: proofreading, checking numbers, careful editing. It helps less before brainstorming, because a narrower focus is the whole effect.")
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
}

struct NotchGalleryView: View {
    @ObservedObject var state: NotchState
    let notchHeight: CGFloat
    let onPick: (CuteCategory) -> Void
    let onAbout: () -> Void
    @State private var hovered: String?
    @State private var aboutHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchHeight)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(categories) { c in card(c) }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            HStack(spacing: 5) {
                Text("Research says a peek at baby animals sharpens your focus, so I put it one hover away.")
                    .foregroundColor(.white.opacity(0.72))
                Text("See why ›")
                    .fontWeight(.semibold)
                    .foregroundColor(Color(red: 1.0, green: 0.62, blue: 0.72))
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

    private func card(_ c: CuteCategory) -> some View {
        VStack(spacing: 6) {
            Text(c.emoji).font(.system(size: 44))
            Text(c.name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white)
        }
        .frame(width: 104, height: 112)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(hovered == c.id ? 0.2 : 0.08)))
        .scaleEffect(hovered == c.id ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .contentShape(Rectangle())
        .onHover { h in if h { hovered = c.id } else if hovered == c.id { hovered = nil } }
        .onTapGesture { onPick(c) }
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
    private var previousApp: NSRunningApplication?
    private var timer: Timer?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var cooldownUntil = Date.distantPast
    private let state = NotchState()

    func start() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
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

    private func showPanel(on screen: NSScreen) {
        let nh = notchHeight(screen)
        let w: CGFloat = 680
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
            let hv = FirstMouseHostingView(rootView: NotchGalleryView(state: state, notchHeight: nh, onPick: { [weak self] c in self?.openSpotlight(c) }, onAbout: { [weak self] in self?.openResearch() }))
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

    func openSpotlight(_ c: CuteCategory) {
        hidePanel()
        if spotlight != nil { closeSpotlight() }
        guard let screen = notchScreen() else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let m = PlayerModel(category: c)
        model = m
        let size = CGSize(width: min(880, screen.frame.width - 80), height: min(680, screen.frame.height - 120))
        let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hv = FirstMouseHostingView(rootView: SpotlightView(model: m, cardSize: size, close: { [weak self] in self?.closeSpotlight() }))
        hv.sizingOptions = []
        w.contentView = hv
        w.alphaValue = 0
        spotlight = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 1
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            let handled: Bool = MainActor.assumeIsolated {
                switch code {
                case 53: self?.closeSpotlight(); return true
                case 124, 49: self?.model?.next(); return true
                case 123: self?.model?.prev(); return true
                default: return false
                }
            }
            return handled ? nil : e
        }
        m.load()
    }

    func openResearch() {
        hidePanel()
        if spotlight != nil { closeSpotlight() }
        guard let screen = notchScreen() else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let size = CGSize(width: min(640, screen.frame.width - 80), height: min(640, screen.frame.height - 120))
        let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hv = FirstMouseHostingView(rootView: ResearchView(cardSize: size, close: { [weak self] in self?.closeSpotlight() }))
        hv.sizingOptions = []
        w.contentView = hv
        w.alphaValue = 0
        spotlight = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 1
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.closeSpotlight() }
            return nil
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

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = NotchController()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        si.button?.title = "🐾"
        let menu = NSMenu()
        let header = NSMenuItem(title: "Hover the notch, or pick one:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (i, c) in categories.enumerated() {
            let mi = NSMenuItem(title: "\(c.emoji)  \(c.name)", action: #selector(pick(_:)), keyEquivalent: "")
            mi.tag = i
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let why = NSMenuItem(title: "Why cute things help…", action: #selector(about), keyEquivalent: "")
        why.target = self
        menu.addItem(why)
        menu.addItem(NSMenuItem(title: "Quit NotchCute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        si.menu = menu
        statusItem = si
    }

    @objc func pick(_ sender: NSMenuItem) { controller.openSpotlight(categories[sender.tag]) }
    @objc func about() { controller.openResearch() }
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
