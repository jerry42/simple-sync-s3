import Foundation
import S5Core

// Synchro unique sans interface, pour tester une configuration :
//   s5-sync --config <chemin> [--state <chemin>]
// Code de sortie : 0 si tout va bien, 1 si la synchro a des erreurs, 2 si la configuration est invalide.

let usage = """
Usage : s5-sync --config <config.json> [--state <state.json>] [--login]
  --config  configuration à utiliser (même format que l'app)
  --state   cache de synchro (par défaut : state.json à côté de la configuration)
  --login   se connecter d'abord à IAM Identity Center (profil SSO), via le navigateur
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
    default: fail("Option inconnue : \(arg)\n\(usage)", code: 2)
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
    fail("Configuration \(configURL.path) : \(error.localizedDescription)", code: 2)
}

if login {
    guard let profile = config.awsProfile else { fail("--login demande \"awsProfile\" dans la configuration", code: 2) }
    do {
        try SSOLogin.login(profile: profile) { authorization in
            print("Valide le code \(authorization.userCode) sur \(authorization.verificationURL.absoluteString)")
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
Log.info("Synchro lancée (ligne de commande, config \(configURL.path), état \(stateURL.path))")
let report: SyncReport
do {
    report = try await SyncEngine(config: config, stateURL: stateURL, progress: { _ in }).run()
} catch {
    Log.info("Synchro impossible : \(error.localizedDescription)")
    Log.flush()
    exit(1)
}
Log.info("Synchro terminée en \(String(format: "%.1f", Date().timeIntervalSince(start))) s : \(report.summary)")
for error in report.errors { Log.info("  • \(error)") }
Log.flush()
exit(report.errors.isEmpty && !report.cancelled ? 0 : 1)
