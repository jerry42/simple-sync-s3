import Foundation
import S5Core

// Synchro unique sans interface, pour tester une configuration (messages en anglais) :
//   s5-sync --config <chemin> [--state <chemin>]
// Code de sortie : 0 si tout va bien, 1 si la synchro a des erreurs, 2 si la configuration est invalide.

let usage = """
Usage: s5-sync --config <config.json> [--state <state.json>] [--login]
  --config  configuration to use (same format as the app)
  --state   sync cache (default: state.json next to the configuration)
  --login   sign in to IAM Identity Center first (SSO profile), in the browser
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var configPath: String?
var statePath: String?
var login = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--config": configPath = args.popFirst()
    case "--state": statePath = args.popFirst()
    case "--login": login = true
    case "--once": break // seul mode disponible, accepté pour la lisibilité
    case "-h", "--help": print(usage); exit(0)
    default: fail("Unknown option: \(arg)\n\(usage)", code: 2)
    }
}

guard let configPath else { fail(usage, code: 2) }
let configURL = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
let stateURL = statePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? configURL.deletingLastPathComponent().appendingPathComponent("state.json")

let config: AppConfig
do {
    config = try ConfigStore.load(from: configURL)
} catch {
    fail("Configuration \(configURL.path): \(error.localizedDescription)", code: 2)
}

if login {
    guard let profile = config.awsProfile else { fail("--login requires \"awsProfile\" in the configuration", code: 2) }
    do {
        try SSOLogin.login(profile: profile) { authorization in
            print("Approve code \(authorization.userCode) at \(authorization.verificationURL.absoluteString)")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [authorization.verificationURL.absoluteString]
            try? open.run()
        }
    } catch {
        Log.info(error.localizedDescription)
        Log.flush()
        exit(1)
    }
}

let start = Date()
Log.info("Sync started (command line, config \(configURL.path), state \(stateURL.path))")
let report: SyncReport
do {
    report = try await SyncEngine(config: config, stateURL: stateURL, progress: { _ in }).run()
} catch {
    Log.info("Sync failed: \(error.localizedDescription)")
    Log.flush()
    exit(1)
}
Log.info("Sync finished in \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(report.summary)")
for error in report.errors { Log.info("  • \(error)") }
Log.flush()
exit(report.errors.isEmpty && !report.cancelled ? 0 : 1)
