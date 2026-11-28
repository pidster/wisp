import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WispCore

/// What `Wisp.app` does when opened from the Finder, with no terminal: a window (`AppPanel`, `AppPanelView`,
/// [ADR 0091](../../../docs/decisions/0091-wisp-app-window.md)) that offers to put wisp on `PATH` (ADR 0073), lists the
/// recent releases and installs the newest (ADR 0074), and manages the models, each through the same calls the
/// terminal's `wisp install`, `wisp update`, and `wisp models` make. Closing the window quits.
enum FinderLaunch {
    /// Whether this process was opened from the Finder.
    static var isCurrent: Bool {
        AppInstall.isFinderLaunch(
            arguments: CommandLine.arguments, stdinIsTerminal: isatty(STDIN_FILENO) != 0, parent: getppid(),
            inApp: PackageLayout.current.layout?.app != nil)
    }

    /// Opens the window and runs until it is closed.
    @MainActor static func run() async {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let controller = Controller()
        application.delegate = controller
        application.mainMenu = menu(controller)
        let session: Session
        do {
            session = try Wisp.begin(.init(entryPoint: .models))
        } catch {
            let alert = Sheets.alert("Wisp Could Not Start", "\(error)", style: .warning)
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return
        }
        defer { session.end() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wisp"
        window.isReleasedWhenClosed = false
        let sheets = Sheets(window: window)
        let panel = AppPanel(services: services(session), prompts: sheets.prompts)
        // Toolbar tabs, one pane each, as a macOS settings window has them; the window takes the selected tab's title.
        let tabs = Tabs()
        tabs.tabStyle = .toolbar
        for pane in AppPanelView.Pane.allCases {
            let hosting = NSHostingController(rootView: AppPanelView(panel: panel, pane: pane))
            // The tab controller sizes the window to the pane's own size, as a settings window does.
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = pane.rawValue
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        // A person with wisp not yet on PATH starts at Install; anyone else at Models.
        tabs.selectedTabViewItemIndex =
            AppPanelView.Pane.allCases.firstIndex(of: panel.welcome.offersInstall ? .install : .models) ?? 0
        window.toolbarStyle = .preference
        window.center()
        window.delegate = controller
        controller.window = window
        controller.tabs = tabs
        controller.panel = panel
        window.makeKeyAndOrderFront(nil)
        application.activate()
        Task { await panel.start() }
        // The window's events run here; closing it, or Quit, stops the loop, and the session ends before wisp exits.
        application.run()
    }

    /// The standard macOS menu bar (Human Interface Guidelines, "The menu bar"): the app menu, File, Edit, Window, and
    /// Help, with their usual items and shortcuts.
    ///
    /// - Parameter controller: The target of Help.
    /// - Returns: The menu bar.
    @MainActor private static func menu(_ controller: Controller) -> NSMenu {
        let application = NSApplication.shared
        let bar = NSMenu()
        let app = NSMenu(title: "Wisp")
        app.addItem(
            withTitle: "About Wisp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        // Where Mac apps put it: below About, opening the Updates tab and checking (ADR 0091).
        app.addItem(
            withTitle: "Check for Updates…", action: #selector(Controller.checkForUpdates(_:)), keyEquivalent: ""
        )
        .target = controller
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        application.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Wisp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        ).keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        application.windowsMenu = window
        let help = NSMenu(title: "Help")
        let guide = help.addItem(withTitle: "Wisp Help", action: #selector(Controller.showHelp(_:)), keyEquivalent: "?")
        guide.target = controller
        application.helpMenu = help
        for menu in [app, file, edit, window, help] {
            let item = NSMenuItem()
            item.submenu = menu
            bar.addItem(item)
        }
        return bar
    }

    /// The window's tabs, which title the window after the selected pane, as a settings window is titled.
    @MainActor private final class Tabs: NSTabViewController {
        /// Selects the pane and titles the window after it.
        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            if let label = tabViewItem?.label { view.window?.title = label }
        }
    }

    /// The application's and the window's delegate: closing the window ends the loop, Quit closes the window rather than
    /// exiting at once, so the session ends and the backends shut down, and Help opens the guide.
    @MainActor private final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
        /// The window, closed by Quit.
        weak var window: NSWindow?
        /// The window's tabs, which Check for Updates switches to Updates.
        weak var tabs: NSTabViewController?
        /// What the window shows and does.
        var panel: AppPanel?

        /// The page of the guide that describes the window.
        static let guide = URL(string: "https://wisp.pidster.com/docs/wisp.html")

        /// Quit closes the window, which stops the loop; wisp then exits as a command does.
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard let window, window.isVisible else { return .terminateNow }
            window.performClose(nil)
            return .terminateCancel
        }

        /// Stops the loop, and posts an event so it notices at once.
        func windowWillClose(_ notification: Notification) {
            let application = NSApplication.shared
            application.stop(nil)
            if let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0)
            {
                application.postEvent(event, atStart: false)
            }
        }

        /// Check for Updates…: shows the Updates tab and asks GitHub, as its button does.
        @objc func checkForUpdates(_ sender: Any?) {
            if let tabs, let index = AppPanelView.Pane.allCases.firstIndex(of: .updates) {
                tabs.selectedTabViewItemIndex = index
            }
            window?.makeKeyAndOrderFront(nil)
            guard let panel else { return }
            Task { await panel.checkForUpdates() }
        }

        /// Disables Check for Updates while a check or an update runs.
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard item.action == #selector(checkForUpdates(_:)), let panel else { return true }
            return panel.update != .checking && !panel.isUpdating
        }

        /// Opens the guide in the person's browser.
        @objc func showHelp(_ sender: Any?) {
            if let guide = Self.guide { NSWorkspace.shared.open(guide) }
        }
    }

    // MARK: - What the window does

    /// The panel's services, as `wisp install`, `wisp update`, and `wisp models` do them, recorded with the source
    /// `finder`.
    ///
    /// - Parameter session: The window's session, whose audit records the model actions.
    /// - Returns: The services.
    @MainActor private static func services(_ session: Session) -> AppPanel.Services {
        let environment = ProcessInfo.processInfo.environment
        let home = ShellCompletions.home(environment: environment)
        let folder = AppInstall.folder(nil, home: home)
        let source = AppInstall.source(of: PackageLayout.current)
        let actions = ModelActions(session: session, face: .finder)
        let checking = session.config.updatesCheck
        let tools = ToolRegistry(
            runner: session.config.runner, disabled: session.config.disabledTools, custom: session.config.customTools
        ).all
        return AppPanel.Services(
            welcome: {
                // The Finder's PATH is launchd's, without Homebrew's bin, so the cask's links are looked for there.
                let brewBin = HomebrewMove.prefix(environment).appending(path: "bin").path
                let linked = source.app.flatMap {
                    AppInstall.linkedElsewhere(
                        app: $0, folder: folder, path: brewBin + ":" + (environment["PATH"] ?? ""))
                }
                return AppInstall.welcome(source: source, folder: folder, home: home, linked: linked)
            },
            install: {
                guard case .app(let app) = source else { throw AppInstall.Failure.refused(source.refusal ?? "") }
                var lines = try AppInstall.install(app: app, folder: folder, force: false, home: home).lines
                // The Finder's PATH is launchd's, not a terminal's, so the advice is given as a condition.
                let shell = ShellCompletions.detect(shellPath: environment["SHELL"])
                lines += [""] + AppInstall.pathAdvice(folder, shell: shell, home: home, known: false)
                lines += ["", "Open a terminal and run wisp chat."]
                return lines
            },
            releases: {
                let result = await AppUpdate.checkListing(home: Wisp.home, source: "finder", audit: session.audit)
                return (result.releases, result.failure.map { "\($0)" })
            },
            lastCheck: { checking ? AppUpdate.state(home: Wisp.home) : nil },
            checkIsDue: { checking && AppUpdate.isDue(AppUpdate.state(home: Wisp.home), now: Date()) },
            update: { release in await update(to: release, source: source, session: session) },
            source: source,
            models: { await actions.list(tools: tools) },
            setEnabled: { name, on, say in
                try await actions.set(enable: on ? [name] : [], disable: on ? [] : [name], report: say)
            },
            check: { name, say in try await actions.check([name], force: true, report: say) },
            uninstall: { name, dialog in
                try await actions.uninstall(name, purgeCache: false, yes: false, dialog: dialog)
            },
            pull: { text, dialog in try await actions.pull(text, dialog: dialog) },
            add: { file in
                try actions.add(file.path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
            })
    }

    /// Replaces the app with `release`, as `wisp update` does, and says what came of it.
    ///
    /// - Parameters:
    ///   - release: The newest release.
    ///   - source: The install.
    ///   - session: The window's session, whose audit records the update.
    /// - Returns: The headline and text to show.
    @MainActor private static func update(
        to release: AppUpdate.Release, source: AppInstall.Source, session: Session
    ) async -> (title: String, text: String) {
        let current = WispVersion.current
        let app: URL
        do {
            app = try AppUpdate.app(of: source)
        } catch {
            return ("Wisp Was Not Updated", "\(error).")
        }
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        do {
            let outcome = try await AppUpdate.update(
                app, to: release, downloads: downloads, audit: session.audit, source: "finder", note: { _ in })
            switch outcome {
            case .replaced(_, _, let to):
                // Launch Services and the router's Login Item learn of the new app; a warning is shown, not a failure.
                var said: [String] = []
                let mended = LlamaCppAgent.afterUpdate(
                    app: app, home: Wisp.home, audit: session.audit, say: { said.append($0) })
                let warnings = mended ? "" : "\n\n" + said.filter { $0.hasPrefix("warning: ") }.joined(separator: "\n")
                return (
                    "Wisp Is Updated to \(to)",
                    "Quit and open Wisp again to use it. The links wisp install made still work. Wisp "
                        + "chats and MCP servers already running keep \(current) until they are started again.\(warnings)"
                )
            case .blocked(let reason, let image):
                _ = AppUpdate.run("/usr/bin/open", [image.path])
                return (
                    "Wisp Could Not Replace Itself",
                    "\(reason).\n\nThe checked disk image is open: drag Wisp.app onto Applications there to replace "
                        + "this one."
                )
            }
        } catch {
            return ("Wisp Was Not Updated", "\(error). This app is unchanged.")
        }
    }
}

/// The window's questions, as sheets on it, and the file panel.
@MainActor private struct Sheets {
    /// The window the sheets attach to.
    let window: NSWindow

    /// The panel's prompts.
    var prompts: AppPanel.Prompts {
        AppPanel.Prompts(
            confirm: { title, text, button in
                // The action the person started is the default; Cancel answers Escape (Human Interface Guidelines,
                // "Alerts").
                let alert = Self.alert(title, text)
                alert.addButton(withTitle: button)
                alert.addButton(withTitle: "Cancel")
                return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
            },
            typed: { title, text in
                // Removing a model is destructive: its button says so, and Return cancels.
                let alert = Self.alert(title, text, style: .warning)
                let remove = alert.addButton(withTitle: "Uninstall")
                let cancel = alert.addButton(withTitle: "Cancel")
                remove.hasDestructiveAction = true
                remove.keyEquivalent = ""
                cancel.keyEquivalent = "\r"
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                field.placeholderString = "Model name"
                alert.accessoryView = field
                alert.window.initialFirstResponder = field
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
                return field.stringValue
            },
            publisher: { lines in
                // Running an untrusted publisher's weights is the risky choice, so Return cancels.
                let alert = Self.alert(lines.first ?? "", lines.dropFirst().dropLast().joined(separator: "\n"))
                let once = alert.addButton(withTitle: "Pull Once")
                alert.addButton(withTitle: "Trust Publisher and Pull")
                let cancel = alert.addButton(withTitle: "Cancel")
                once.keyEquivalent = ""
                cancel.keyEquivalent = "\r"
                switch await alert.beginSheetModal(for: window) {
                case .alertFirstButtonReturn: return .once
                case .alertSecondButtonReturn: return .trust
                default: return .refuse
                }
            },
            file: {
                let panel = NSOpenPanel()
                panel.message = "Choose a GGUF file for wisp's llama.cpp server. It stays where it is; wisp links it."
                panel.prompt = "Add"
                panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                guard await panel.beginSheetModal(for: window) == .OK else { return nil }
                return panel.url
            },
            tell: { title, text in
                let alert = Self.alert(title, text)
                alert.addButton(withTitle: "OK")
                _ = await alert.beginSheetModal(for: window)
            })
    }

    /// An alert with a headline and text, no buttons yet.
    ///
    /// - Parameters:
    ///   - title: The headline.
    ///   - text: The text.
    ///   - style: Its style.
    /// - Returns: The alert.
    static func alert(_ title: String, _ text: String, style: NSAlert.Style = .informational) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        return alert
    }
}
