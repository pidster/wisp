import SwiftUI
import WispCore

/// One pane of `Wisp.app`'s window ([ADR 0091](../../../docs/decisions/0091-wisp-app-window.md)), shown under its tab
/// in the window's toolbar as Apple's Human Interface Guidelines lay out a settings window: a grouped form, standard
/// controls (a switch for a model's on or off state, a menu for its other actions), title-case buttons with an ellipsis
/// where more input follows, and the system's warning symbol. `AppPanel` does the work.
struct AppPanelView: View {
    /// The window's panes, one per tab.
    enum Pane: String, CaseIterable {
        /// Whether wisp is on `PATH`, and the offer to link it.
        case install = "Install"
        /// The version, the recent releases, and Update.
        case updates = "Updates"
        /// The models, adding one, and what the actions said.
        case models = "Models"

        /// The tab's SF Symbol.
        var symbol: String {
            switch self {
            case .install: "square.and.arrow.down"
            case .updates: "arrow.triangle.2.circlepath"
            case .models: "cpu"
            }
        }
    }

    /// What the window shows and does.
    let panel: AppPanel
    /// The pane this view shows.
    let pane: Pane
    /// The repository typed for a pull.
    @State private var repository = ""

    /// The pane's sections, in a grouped form.
    var body: some View {
        Form {
            switch pane {
            case .install:
                install
            case .updates:
                updates
            case .models:
                models
                addModel
                if !panel.log.isEmpty { activity }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: pane == .install ? 260 : 560)
    }

    // MARK: - Install

    /// Whether wisp is on `PATH`, and the offer to link it.
    private var install: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(panel.welcome.title)
                Text(panel.welcome.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if panel.welcome.offersInstall {
                HStack {
                    Spacer()
                    Button("Install") { panel.install() }
                }
            }
            if let note = panel.installNote {
                Text(note).font(.callout).textSelection(.enabled)
            }
        }
    }

    // MARK: - Updates

    /// The running version, the recent releases, and Update for the newest.
    private var updates: some View {
        Section {
            LabeledContent("Version", value: panel.version)
            HStack {
                status
                Spacer()
                if case .listed(_, _, let release?) = panel.update {
                    Button("Update to \(release.version)…") { Task { await panel.installUpdate() } }
                }
                Button("Check for Updates") { Task { await panel.checkForUpdates() } }
                    .disabled(panel.update == .checking || panel.isUpdating)
            }
            if case .listed(let releases, _, _) = panel.update {
                ForEach(releases, id: \.release.version) { published in
                    release(published, newest: published.release.version == releases.first?.release.version)
                }
            }
        } footer: {
            Text(
                "Checking sends one request to GitHub, with nothing about you or this Mac. Only the newest release "
                    + "can be installed."
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What the update section says now.
    @ViewBuilder private var status: some View {
        switch panel.update {
        case .idle(let text):
            Text(text).font(.callout).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                .font(.callout).textSelection(.enabled)
        case .updating(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .listed(_, let advice, _):
            Text(advice).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// One release: its version, day, and marks, with its notes folded away.
    ///
    /// - Parameters:
    ///   - published: The release.
    ///   - newest: Whether it is the newest.
    /// - Returns: The row.
    private func release(_ published: AppUpdate.Published, newest: Bool) -> some View {
        let running = AppUpdate.Version(panel.version).map { "\($0)" } == published.release.version
        let marks = [newest ? "Newest" : nil, running ? "Installed" : nil].compactMap(\.self)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(AppUpdate.summary(of: published.notes, limit: 40).enumerated()), id: \.offset) { line in
                    Text(line.element).font(.callout)
                }
                if let page = published.release.page {
                    Link("Release Notes on GitHub", destination: page).font(.callout)
                }
            }
            .textSelection(.enabled)
        } label: {
            LabeledContent {
                Text(([published.day] + marks).filter { !$0.isEmpty }.joined(separator: " · "))
            } label: {
                Text("Wisp \(published.release.version)")
            }
        }
    }

    // MARK: - Models

    /// The models, each with a switch and a menu of its other actions.
    private var models: some View {
        Section {
            if panel.models.isEmpty {
                Text(panel.listing ? "Listing models…" : "No models are listed.").foregroundStyle(.secondary)
            }
            ForEach(panel.models) { row in model(row) }
        } header: {
            HStack {
                Text("Available Models")
                Spacer()
                if panel.listing { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await panel.refreshModels() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(panel.busy != nil)
                    .help("List the models again")
            }
        } footer: {
            Text(
                "These are the models wisp models list shows. Turning a model on checks what it can do when that is "
                    + "not yet known."
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// One model's row: its name and detail, any problem, a menu of its other actions, and its switch.
    ///
    /// - Parameter row: The model.
    /// - Returns: The row.
    private func model(_ row: AppPanel.ModelRow) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.monospaced())
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary) }
                if let problem = row.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        .font(.caption)
                }
            }
            Spacer()
            Menu {
                Button("Check Capabilities") { Task { await panel.check(row) } }
                if row.removable {
                    Divider()
                    Button("Uninstall…", role: .destructive) { Task { await panel.uninstall(row) } }
                }
            } label: {
                Label("Actions for \(row.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Toggle(
                "Enabled",
                isOn: Binding(get: { row.enabled }, set: { _ in Task { await panel.toggle(row) } })
            )
            .toggleStyle(.switch).labelsHidden()
            .accessibilityLabel("\(row.name) enabled")
        }
        .disabled(panel.busy != nil)
    }

    /// Pull from Hugging Face, or add a GGUF file, with a pull's progress.
    private var addModel: some View {
        Section {
            TextField("Repository", text: $repository, prompt: Text("mlx-community/Qwen3-4B-4bit"))
                .onSubmit { pull() }
            HStack {
                Button("Add GGUF File…") { Task { await panel.add() } }.disabled(panel.busy != nil)
                Spacer()
                Button("Pull…") { pull() }
                    .disabled(panel.busy != nil || repository.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let progress = panel.progress {
                HStack {
                    ProgressView(value: Double(progress.fetched), total: Double(max(progress.total, 1))) {
                        Text("Downloading \(progress.file)").font(.callout)
                    } currentValueLabel: {
                        Text("File \(progress.index) of \(progress.files)").font(.caption)
                    }
                    if panel.canStop { Button("Stop") { panel.stopPull() } }
                }
            } else if let busy = panel.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Add a Model")
        } footer: {
            Text(
                "Pull downloads an MLX model from Hugging Face after asking about its publisher and its size. A GGUF "
                    + "file stays where it is; wisp links it for its llama.cpp server."
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Starts a pull of the typed repository.
    private func pull() {
        guard panel.busy == nil else { return }
        let text = repository
        Task { await panel.pull(text) }
    }

    // MARK: - Activity

    /// What the model actions said, latest last.
    private var activity: some View {
        Section {
            DisclosureGroup("Details") {
                ScrollView {
                    Text(panel.log.suffix(80).joined(separator: "\n")).font(.caption.monospaced())
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        } header: {
            Text("Activity")
        }
    }
}
