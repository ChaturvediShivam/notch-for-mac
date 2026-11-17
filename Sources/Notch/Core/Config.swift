import Foundation

/// Everything the user can change, saved to ~/.notch/config.json.
/// Every field has a default so older/partial files still load.
struct Config: Codable, Equatable {
    // Privacy switches: one per network feature (rule 8). Off = no request is made.
    var netLyrics = true
    var netWeather = true
    var netMarkets = true
    var netScores = true
    var netClaude = true
    var netLocalAPI = true          // loopback only, but still a switch

    var city = ""                   // weather location by name (no Location permission needed)
    var useLocation = false         // opt-in CoreLocation
    var celsius = true
    var watchlist = ["AAPL", "MSFT", "NVDA", "^GSPC", "BTC-USD"]
    var leagues = ["soccer/eng.1", "basketball/nba", "soccer/uefa.champions"]
    var apiPort = 51515
    var claudeBackend = "code"       // "code" = Claude Code CLI, "api" = Anthropic API with your key
    var claudeModel = ""             // Claude Code model; empty = its default
    var claudeAPIModel = "claude-opus-5-5"
    var meetingLocale = "en-IN"
    var meetingAuto = true           // start/stop Meeting mode with Zoom/Meet/Teams calls
    var meetingTopic = ""            // "My words": your work/notes in plain words (answers phrase it professionally)
    var meetingCV = ""               // resume: mine when answering, the candidate's when interviewing
    var meetingJD = ""               // job description / agenda
    var keywordCards = true          // answer cards start with 3–4 keywords to glance at, then the full answer
    var deliveryCoach = false        // practice: camera eye tracking + pacing report after each answer (nothing recorded)
    var meetingRole = "answer"       // "answer" = I'm being asked (interview, meeting); "interview" = I'm asking
    var meetingAI = "claude"         // who writes meeting answers: claude (Claude tab setting), openai, gemini, ollama, custom
    var aiModels: [String: String] = [:]  // model per provider above
    var aiBaseURL = ""               // custom: any OpenAI-compatible endpoint (OpenRouter, Groq, LM Studio…)
    var autoSwitchOutput = true      // plug in USB/Bluetooth earphones → sound moves there
    var claudeCwd = ""               // folder Claude Code runs in; empty = home
    var pinnedApps: [String] = []   // bundle paths
    var keepAwake = false
    var launchAtLogin = false
    var keepAlive = false
    var clipboardLimit = 50
    var clipDays = 7                 // clipboard history lifetime (pinned items stay)
    var alertDays = 30
    var keptDays = 0                 // kept meetings: 0 = until you delete them
    var glass = true                 // Liquid Glass on macOS 26 for the open notch
    var opacity = 1.0                // open notch background, 0.3…1
    var theme = "classic"            // Skin preset id
    var edgeGlow = true              // glow around the open notch + hover glow
    var hiddenTabs: [String] = []    // tab titles; core tabs stay unless master build
    var accentHex = ""               // master build only: custom accent
    var tintHex = ""                 // master build only: custom background wash

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = Config()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        netLyrics = v(.netLyrics, z.netLyrics); netWeather = v(.netWeather, z.netWeather)
        netMarkets = v(.netMarkets, z.netMarkets); netScores = v(.netScores, z.netScores)
        netClaude = v(.netClaude, z.netClaude); netLocalAPI = v(.netLocalAPI, z.netLocalAPI)
        city = v(.city, z.city); useLocation = v(.useLocation, z.useLocation); celsius = v(.celsius, z.celsius)
        watchlist = v(.watchlist, z.watchlist); leagues = v(.leagues, z.leagues)
        apiPort = v(.apiPort, z.apiPort); claudeModel = v(.claudeModel, z.claudeModel); claudeCwd = v(.claudeCwd, z.claudeCwd); meetingLocale = v(.meetingLocale, z.meetingLocale); meetingTopic = v(.meetingTopic, z.meetingTopic); meetingAuto = v(.meetingAuto, z.meetingAuto)
        meetingCV = v(.meetingCV, z.meetingCV); meetingJD = v(.meetingJD, z.meetingJD); meetingRole = v(.meetingRole, z.meetingRole); deliveryCoach = v(.deliveryCoach, z.deliveryCoach); keywordCards = v(.keywordCards, z.keywordCards)
        meetingAI = v(.meetingAI, z.meetingAI); aiModels = v(.aiModels, z.aiModels); aiBaseURL = v(.aiBaseURL, z.aiBaseURL)
        autoSwitchOutput = v(.autoSwitchOutput, z.autoSwitchOutput)
        claudeBackend = v(.claudeBackend, z.claudeBackend); claudeAPIModel = v(.claudeAPIModel, z.claudeAPIModel)
        pinnedApps = v(.pinnedApps, z.pinnedApps); keepAwake = v(.keepAwake, z.keepAwake)
        launchAtLogin = v(.launchAtLogin, z.launchAtLogin); keepAlive = v(.keepAlive, z.keepAlive)
        clipboardLimit = v(.clipboardLimit, z.clipboardLimit); clipDays = v(.clipDays, z.clipDays); alertDays = v(.alertDays, z.alertDays); keptDays = v(.keptDays, z.keptDays); opacity = v(.opacity, z.opacity); glass = v(.glass, z.glass)
        theme = v(.theme, z.theme); edgeGlow = v(.edgeGlow, z.edgeGlow); hiddenTabs = v(.hiddenTabs, z.hiddenTabs)
        accentHex = v(.accentHex, z.accentHex); tintHex = v(.tintHex, z.tintHex)
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    private let url = Paths.home.appendingPathComponent("config.json")

    @Published var config: Config {
        didSet { if config != oldValue { save() } }
    }

    private init() {
        if let d = try? Data(contentsOf: url) {
            if let c = try? JSONDecoder().decode(Config.self, from: d) { config = c; return }
            // Unreadable: keep a copy before defaults overwrite it on the next change.
            try? d.write(to: url.appendingPathExtension("broken"))
        }
        config = Config()
    }

    private func save() {
        let data = try? JSONEncoder.pretty.encode(config)
        let url = url
        DispatchQueue.global(qos: .utility).async { try? data?.write(to: url, options: .atomic) }
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}

/// Small JSON file helpers for per-feature data in ~/.notch.
enum DataFile {
    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(contentsOf: Paths.home.appendingPathComponent(name)))
    }
    static func save<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder.pretty.encode(value) else { return }
        let url = Paths.home.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }
}
