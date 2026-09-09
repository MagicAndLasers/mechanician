import Foundation
import SwiftUI

/// A launch-time readout of every layer that decides which language a string resolves in.
///
/// Localization readiness is a claim about what reaches the screen, and the layers between a
/// `.lproj` on disk and a menu title each fail differently: the bundle may not offer the language,
/// the process may not prefer it, or the lookup may not consult the table. Reading the compiled
/// `.strings` proves only the first. This prints all of them at once so a single launch says which
/// layer broke, rather than one more hypothesis per build.
///
/// Off unless `MECHANICIAN_LOCALIZATION_PROBE` names a writable path, and it writes to that file
/// rather than the unified log — this app's `NSLog` output does not reach `log stream`, which has
/// already cost one debugging cycle to rediscover.
enum MechanicianLocalizationProbe {
    static func writeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["MECHANICIAN_LOCALIZATION_PROBE"],
              !path.isEmpty else { return }

        let bundle = Bundle.main
        // The key is a real File-menu title: `Button("New Conversation")` in FileCommands.
        let key = "New Conversation"
        var lines: [String] = []
        func put(_ label: String, _ value: Any) { lines.append("\(label): \(value)") }

        put("bundlePath", bundle.bundlePath)
        put("bundleIdentifier", bundle.bundleIdentifier ?? "(nil)")
        put("bundle.localizations", bundle.localizations.sorted())
        put("bundle.preferredLocalizations", bundle.preferredLocalizations)
        put("bundle.developmentLocalization", bundle.developmentLocalization ?? "(nil)")
        put("Locale.current", Locale.current.identifier)
        put("Locale.preferredLanguages", Locale.preferredLanguages)
        put("defaults AppleLanguages", UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [])
        put("arguments", ProcessInfo.processInfo.arguments.dropFirst())

        // Three lookups, narrowing from the most abstract to the most explicit. Where they disagree
        // is the layer at fault: `String(localized:)` and `NSLocalizedString` both go through the
        // process's preferred language, while asking the bundle for an explicit `en-XA` table
        // proves whether the compiled resource is present and well-formed at all.
        put("String(localized:)", String(localized: String.LocalizationValue(key)))
        put("NSLocalizedString", NSLocalizedString(key, comment: ""))
        put("bundle.localizedString", bundle.localizedString(forKey: key, value: "(missing)", table: nil))
        if let pseudoPath = bundle.path(forResource: "en-XA", ofType: "lproj"),
           let pseudo = Bundle(path: pseudoPath) {
            put("en-XA bundle direct", pseudo.localizedString(forKey: key, value: "(missing)", table: nil))
        } else {
            put("en-XA bundle direct", "(no en-XA.lproj in bundle)")
        }

        try? (lines.joined(separator: "\n") + "\n").write(
            toFile: path, atomically: true, encoding: .utf8)

        // The menu bar must be read from INSIDE the process. Over the Accessibility API,
        // `menu bar 1` of a non-frontmost process resolves to the system menu bar — which belongs
        // to whichever app is active — so a background build appears to have the foreground app's
        // menus. With two Mechanician bundles installed that reads as "the dev build did not
        // localize" when the dev build was never being looked at.
        //
        // SwiftUI also installs `Commands` menus lazily, when a scene first becomes active, so a
        // single early sample finds no File menu at all. Sample repeatedly and let the transition
        // show up rather than trusting one reading.
        let samples = Int(ProcessInfo.processInfo.environment["MECHANICIAN_LOCALIZATION_PROBE_SAMPLES"] ?? "")
            ?? 8
        for tick in 1...max(1, samples) {
            scheduleMenuDump(after: Double(tick) * 5, tick: tick, key: key, path: path)
        }
    }

    private static func scheduleMenuDump(after seconds: Double, tick: Int, key: String, path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            var later: [String] = ["", "--- sample \(tick) (\(Int(seconds))s) ---"]
            later.append("active: \(NSApp.isActive)")
            later.append("Locale.current: \(Locale.current.identifier)")
            later.append("bundle.preferredLocalizations: \(Bundle.main.preferredLocalizations)")
            later.append("NSLocalizedString: \(NSLocalizedString(key, comment: ""))")
            guard let main = NSApp.mainMenu else {
                later.append("NSApp.mainMenu: nil")
                let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                try? (existing + later.joined(separator: "\n") + "\n").write(
                    toFile: path, atomically: true, encoding: .utf8)
                return
            }
            later.append("mainMenu items: \(main.items.count)")
            // Every top-level submenu, not just the one titled "File". A localized build renames
            // the menu itself, so matching on the English title is exactly the bug this is looking
            // for — and it is the bug at MechanicianApp.swift:1270, which finds the Edit menu that
            // way to retitle Undo/Redo.
            for top in main.items {
                later.append("  [\(top.title)] submenu=[\(top.submenu?.title ?? "nil")]")
                for item in top.submenu?.items.prefix(3) ?? [] where !item.title.isEmpty {
                    later.append("      \(item.title)")
                }
            }
            let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (contents + later.joined(separator: "\n") + "\n").write(
                toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
