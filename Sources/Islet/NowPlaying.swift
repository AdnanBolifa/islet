import AppKit
import IsletCore
import Observation

enum Player: String, CaseIterable {
    case music = "Music", spotify = "Spotify"

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var changeNotification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

enum Browser: String, CaseIterable {
    case safari = "Safari", chrome = "Google Chrome", edge = "Microsoft Edge", brave = "Brave Browser"

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        }
    }

    var shortName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .brave: "Brave"
        }
    }

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// AppleScript that runs `js` in one tab. Needs "Allow JavaScript from Apple Events" in the browser.
    func run(_ js: String, window: Int, tab: Int) -> String {
        self == .safari
            ? "tell application \"Safari\" to do JavaScript \"\(js)\" in tab \(tab) of window \(window)"
            : "tell application \"\(rawValue)\" to execute tab \(tab) of window \(window) javascript \"\(js)\""
    }

    /// AppleScript that lists media tabs as "browser␟window␟tab␟title␟json" lines.
    var scanScript: String {
        let runJS = self == .safari ? "do JavaScript \"\(MediaJS.read)\" in t" : "execute t javascript \"\(MediaJS.read)\""
        let titleOf = self == .safari ? "name of t" : "title of t"
        return """
            tell application "\(rawValue)"
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set u to URL of t
                        if u contains "youtube.com/watch" or u contains "music.youtube.com" or u contains "youtube.com/shorts" or u contains "soundcloud.com/" or u contains "open.spotify.com" then
                            set info to ""
                            try
                                set info to \(runJS)
                            end try
                            set out to out & "\(rawValue)" & sep & wi & sep & ti & sep & (\(titleOf)) & sep & info & linefeed
                        end if
                    end repeat
                end repeat
            end tell
            """
    }
}

/// Page scripts. Single quotes only: they're embedded in AppleScript strings.
enum MediaJS {
    /// Reads the page's media element plus the metadata the site gives the system (navigator.mediaSession).
    static let read = "(()=>{const v=document.querySelector('video,audio');if(!v)return '';const m=navigator.mediaSession&&navigator.mediaSession.metadata;const art=m&&m.artwork&&m.artwork.length?m.artwork[m.artwork.length-1].src:'';return JSON.stringify({playing:!v.paused,title:(m&&m.title)||'',artist:(m&&m.artist)||'',art:art})})()"
    static let toggle = "(()=>{const v=document.querySelector('video,audio');if(v){v.paused?v.play():v.pause()}})()"
    static let next = "(()=>{const b=document.querySelector('.ytp-next-button');if(b)b.click()})()"
    static let previous = "(()=>{const v=document.querySelector('video,audio');if(v)v.currentTime=0})()"
}

struct BrowserTab: Equatable {
    var browser: Browser
    var window: Int
    var tab: Int
}

@MainActor @Observable
final class NowPlayingModel {
    private(set) var player: Player?
    private(set) var browserTab: BrowserTab?
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var artwork: NSImage?
    private(set) var isPlaying = false
    /// The browser blocks page scripts from AppleScript, so play state and controls aren't available.
    private(set) var browserNeedsJavaScript: Browser?

    var hasSource: Bool { player != nil || browserTab != nil }
    var subtitle: String {
        if let tab = browserTab {
            return [artist, tab.browser.shortName].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
        }
        return artist ?? ""
    }

    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var polling = false

    init() {
        // Music and Spotify broadcast every track and state change.
        for player in Player.allCases {
            DistributedNotificationCenter.default().addObserver(forName: .init(player.changeNotification), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated {
                    let state = info["Player State"] as? String
                    self?.setApp(player, playing: state == "Playing", stopped: state == "Stopped",
                                 title: info["Name"] as? String, artist: info["Artist"] as? String)
                }
            }
        }
        // Pick up a song that was already playing before Islet launched.
        for player in Player.allCases where player.isRunning {
            let script = """
                if player state is stopped then return ""
                return (player state as string) & linefeed & (name of current track) & linefeed & (artist of current track)
                """
            guard let lines = runApp(player, script)?.stringValue?.components(separatedBy: "\n"), lines.count == 3 else { continue }
            setApp(player, playing: lines[0] == "playing", stopped: false, title: lines[1], artist: lines[2])
            if isPlaying { break }
        }
        // Browsers don't broadcast, so look at their media tabs every few seconds while one is open.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollBrowsers() }
        }
        pollBrowsers()
    }

    func playPause() { control(app: "playpause", js: MediaJS.toggle) }
    func next() { control(app: "next track", js: MediaJS.next) }
    func previous() { control(app: "previous track", js: MediaJS.previous) }

    private func control(app command: String, js: String) {
        if let player {
            runApp(player, command)
        } else if let tab = browserTab {
            Self.osascript(tab.browser.run(js, window: tab.window, tab: tab.tab)) { [weak self] _ in self?.pollBrowsers() }
        }
    }

    // MARK: Music and Spotify

    private func setApp(_ player: Player, playing: Bool, stopped: Bool, title: String?, artist: String?) {
        if stopped {
            if self.player == player { clear() }
            return
        }
        // Something else pausing shouldn't take the island from what's playing.
        if !playing, isPlaying, self.player != player { return }
        browserTab = nil
        browserNeedsJavaScript = nil
        self.player = player
        show(title: title, artist: artist, playing: playing, key: "\(player)") { [weak self] key in
            self?.loadAppArtwork(player, key: key)
        }
    }

    private func loadAppArtwork(_ player: Player, key: String) {
        switch player {
        case .music:
            if let data = runApp(.music, "get raw data of artwork 1 of current track")?.data { artwork = NSImage(data: data) }
        case .spotify:
            if let link = runApp(.spotify, "get artwork url of current track")?.stringValue { loadArtwork(from: link, key: key) }
        }
    }

    /// The first call asks the user for Automation permission.
    @discardableResult
    private func runApp(_ player: Player, _ body: String) -> NSAppleEventDescriptor? {
        guard player.isRunning else { return nil } // never launch the player just to ask about it
        var error: NSDictionary?
        return NSAppleScript(source: "tell application \"\(player.rawValue)\"\n\(body)\nend tell")?.executeAndReturnError(&error)
    }

    // MARK: Browsers

    private func pollBrowsers() {
        if player != nil, isPlaying { return } // Music/Spotify playing wins
        let browsers = Browser.allCases.filter(\.isRunning)
        guard !polling else { return }
        guard !browsers.isEmpty else { if browserTab != nil { clear() }; return }
        polling = true
        // Only running browsers go in the script; naming one that isn't installed would pop up a "Where is…?" dialog.
        let script = "set out to \"\"\nset sep to character id 31\n" + browsers.map(\.scanScript).joined(separator: "\n") + "\nreturn out"
        Self.osascript(script) { [weak self] output in
            self?.polling = false
            self?.applyScan(output)
        }
    }

    private func applyScan(_ output: String?) {
        guard let output else { return } // Automation denied or the browser was busy; keep what we have
        if player != nil, isPlaying { return }

        struct Found { var tab: BrowserTab; var tabTitle: String; var media: [String: Any]? }
        let found: [Found] = output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let browser = Browser(rawValue: fields[0]),
                  let window = Int(fields[1]), let tab = Int(fields[2]) else { return nil }
            let media = try? JSONSerialization.jsonObject(with: Data(fields[4].utf8)) as? [String: Any]
            return Found(tab: BrowserTab(browser: browser, window: window, tab: tab), tabTitle: fields[3], media: media)
        }
        // Prefer a tab that's playing, then one we can read, then any media tab.
        guard let pick = found.first(where: { $0.media?["playing"] as? Bool == true })
            ?? found.first(where: { $0.media != nil }) ?? found.first
        else {
            if browserTab != nil { clear() }
            return
        }

        player = nil
        browserTab = pick.tab
        browserNeedsJavaScript = pick.media == nil ? pick.tab.browser : nil
        let media = pick.media ?? [:]
        let title = (media["title"] as? String)?.nilIfEmpty ?? cleanMediaTabTitle(pick.tabTitle)
        show(title: title, artist: media["artist"] as? String, playing: media["playing"] as? Bool ?? false,
             key: pick.tab.browser.rawValue) { [weak self] key in
            if let link = (media["art"] as? String)?.nilIfEmpty { self?.loadArtwork(from: link, key: key) }
        }
    }

    /// Runs AppleScript off the main thread through osascript, so a slow browser never stalls the UI.
    private static let scriptQueue = DispatchQueue(label: "islet.osascript")
    private static func osascript(_ source: String, completion: @escaping @MainActor (String?) -> Void) {
        scriptQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var text: String?
            if (try? process.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { text = String(decoding: data, as: UTF8.self) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(text) } }
        }
    }

    // MARK: Shared

    private func show(title: String?, artist: String?, playing: Bool, key source: String, loadArt: (String) -> Void) {
        self.title = title
        self.artist = artist
        isPlaying = playing
        let key = "\(source)|\(title ?? "")|\(artist ?? "")"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        loadArt(key)
    }

    private func loadArtwork(from link: String, key: String) {
        guard let url = URL(string: link), url.scheme == "https" else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), artworkKey == key else { return }
            artwork = NSImage(data: data)
        }
    }

    private func clear() {
        player = nil
        browserTab = nil
        browserNeedsJavaScript = nil
        title = nil
        artist = nil
        artwork = nil
        isPlaying = false
        artworkKey = ""
    }
}
