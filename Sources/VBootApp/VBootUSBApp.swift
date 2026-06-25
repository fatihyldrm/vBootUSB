import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VBootCore

@main
struct VBootUSBApp: App {
    var body: some Scene {
        Window("vBootUSB", id: "main") {
            ContentView()
                .frame(width: 500)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum BootSelection: String, CaseIterable, Identifiable {
        case image = "Disk or ISO image"
        case nonBootable = "Non bootable"
        var id: String { rawValue }
    }

    @Published var devices: [StorageDevice] = []
    @Published var selectedDeviceID: String?
    @Published var bootSelection: BootSelection = .image
    @Published var isoPath: String?
    @Published var analysis: ISOAnalysis?
    @Published var analyzing = false
    @Published var partitionScheme: PartitionScheme = .mbr
    @Published var fileSystem: FileSystemType = .fat32
    @Published var volumeLabel = "VBOOTUSB"
    @Published var quickFormat = true
    @Published var isBusy = false
    @Published var progress: Double = 0
    @Published var statusText = "READY"
    @Published var log = ""
    @Published var showResult = false
    @Published var resultSuccess = false
    @Published var showAbout = false
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var updateURL = "https://github.com/fatihyldrm/vBootUSB/releases"
    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    let repoURL = "https://github.com/fatihyldrm/vBootUSB"

    var selectedDevice: StorageDevice? { devices.first { $0.id == selectedDeviceID } }
    var needsISO: Bool { bootSelection == .image }
    var canStart: Bool {
        guard !isBusy, selectedDevice != nil else { return false }
        return needsISO ? (isoPath != nil && analysis != nil) : true
    }

    func checkForUpdates(manual: Bool = false) {
        let cur = currentVersion
        guard let url = URL(string: "https://raw.githubusercontent.com/fatihyldrm/vBootUSB/main/latest.json") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        Task.detached {
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ver = obj["version"] as? String else {
                if manual { await MainActor.run { self.statusText = "Update check failed." } }
                return
            }
            let link = (obj["url"] as? String) ?? "https://github.com/fatihyldrm/vBootUSB/releases"
            let newer = Self.isNewer(ver, than: cur)
            await MainActor.run {
                self.latestVersion = ver
                self.updateURL = link
                self.updateAvailable = newer
                if manual && !newer { self.statusText = "You're up to date (v\(cur))." }
            }
        }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    func refreshDevices() {
        Task.detached(priority: .userInitiated) {
            let devs = DiskEnumerator().writeEligibleDevices()
            await MainActor.run {
                self.devices = devs
                if self.selectedDeviceID == nil || !devs.contains(where: { $0.id == self.selectedDeviceID }) {
                    self.selectedDeviceID = devs.first?.id
                }
            }
        }
    }

    func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = []
        if let iso = UTType(filenameExtension: "iso") { types.append(iso) }
        if let img = UTType(filenameExtension: "img") { types.append(img) }
        types.append(.diskImage)
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bootSelection = .image
        isoPath = url.path
        analyze()
    }

    func analyze() {
        guard let path = isoPath else { return }
        analyzing = true; analysis = nil; statusText = "Inspecting ISO…"
        Task.detached(priority: .userInitiated) {
            let result = try? ISOAnalyzer().analyze(path: path)
            await MainActor.run {
                self.analysis = result
                self.analyzing = false
                if let a = result {
                    self.partitionScheme = (a.type == .windows) ? .gpt : .mbr
                    self.fileSystem = .fat32
                    let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    let clean = base.uppercased().filter { $0.isLetter || $0.isNumber }
                    if !clean.isEmpty { self.volumeLabel = String(clean.prefix(11)) }
                    self.statusText = "READY"
                } else {
                    self.statusText = "Could not analyze ISO."
                }
            }
        }
    }

    func start() {
        guard let dev = selectedDevice else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .critical
        confirm.messageText = "\(dev.displayName) will be erased"
        confirm.informativeText = needsISO
            ? "All data on \(dev.bsdName) will be lost and the image will be written."
            : "All data on \(dev.bsdName) will be lost and the drive will be formatted."
        confirm.addButton(withTitle: "START")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        isBusy = true; progress = 0; statusText = "Preparing… (admin password required)"; log = ""

        let helper = Self.helperPath()
        let pf = NSTemporaryDirectory() + "vbootusb-\(ProcessInfo.processInfo.processIdentifier).progress"
        try? FileManager.default.removeItem(atPath: pf)

        let schemeArg = partitionScheme.rawValue
        let fsArg = fileSystem.rawValue
        let labelArg = volumeLabel
        let nonBootable = (bootSelection == .nonBootable)
        let iso = isoPath
        let a = analysis
        let modeDD = needsISO && (a?.recommendedMode == .dd)
        let isoSize = a?.sizeBytes ?? 0
        let typeArg = a?.type.rawValue ?? "unknown"
        let isWindows = (a?.type == .windows)
        let installSize = a?.installImageSizeBytes
        let fsEnum = fileSystem

        let poll = Task { @MainActor in
            while self.isBusy && !Task.isCancelled {
                if let s = try? String(contentsOfFile: pf, encoding: .utf8) {
                    let parts = s.split(separator: "|", maxSplits: 1)
                    if let f = Double(parts.first.map(String.init) ?? "") { self.progress = f }
                    if parts.count > 1 { self.statusText = String(parts[1]) }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        Task.detached(priority: .userInitiated) {
            var outcome: (ok: Bool, output: String)

            if nonBootable {
                let cmd = "\(helper) format --device \(dev.bsdName) --scheme \(schemeArg)"
                    + " --filesystem \(fsArg) --label \(Self.shQuote(labelArg))"
                    + " --progress-file \(Self.shQuote(pf)) --yes"
                outcome = Self.runWithAdmin(cmd)

            } else if modeDD {
                if let iso, let attached = try? ISOMounter.attach(isoPath: iso) {
                    let rdev = "/dev/r" + (attached.devEntry as NSString).lastPathComponent
                    let cmd = "\(helper) write --device \(dev.bsdName) --mode dd --type \(typeArg)"
                        + " --source-device \(Self.shQuote(rdev)) --source-size \(isoSize)"
                        + " --progress-file \(Self.shQuote(pf)) --yes"
                    outcome = Self.runWithAdmin(cmd)
                    ISOMounter.detach(attached)
                } else {
                    outcome = (false, "Could not mount ISO.")
                }

            } else {
                guard let iso else { outcome = (false, "No ISO selected."); await self.finish(outcome, poll, pf, dev); return }
                let fmtCmd = "\(helper) format --device \(dev.bsdName) --scheme \(schemeArg)"
                    + " --filesystem \(fsArg) --label \(Self.shQuote(labelArg))"
                    + " --progress-file \(Self.shQuote(pf)) --yes"
                let fmt = Self.runWithAdmin(fmtCmd)
                if let mount = Self.parseMount(fmt.output), fmt.ok,
                   let attached = try? ISOMounter.attach(isoPath: iso),
                   let srcMount = ISOAnalyzer.primaryMountPoint(attached.mountPoints) {
                    do {
                        try USBWriter().copyContents(
                            fromMount: srcMount, toMount: mount, isWindows: isWindows,
                            installImageSize: installSize, fileSystem: fsEnum, totalBytes: isoSize,
                            progress: { p in
                                try? "\(p.fraction)|\(p.phase)".write(toFile: pf, atomically: true, encoding: .utf8)
                            })
                        Self.ejectUser(dev)
                        outcome = (true, "Files copied (\(schemeArg) + \(fsArg)).")
                    } catch {
                        outcome = (false, "\(error)")
                    }
                    ISOMounter.detach(attached)
                } else {
                    outcome = (false, fmt.output.isEmpty ? "Format failed." : fmt.output)
                }
            }
            await self.finish(outcome, poll, pf, dev)
        }
    }

    func finish(_ outcome: (ok: Bool, output: String), _ poll: Task<Void, Never>, _ pf: String, _ dev: StorageDevice) {
        poll.cancel()
        log = outcome.output
        progress = outcome.ok ? 1.0 : progress
        statusText = outcome.ok ? "DONE — \(dev.bsdName) is ready" : "FAILED"
        isBusy = false
        try? FileManager.default.removeItem(atPath: pf)
        resultSuccess = outcome.ok
        showResult = true
        refreshDevices()
    }

    static func helperPath() -> String {
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vbootusb").path
        if FileManager.default.isExecutableFile(atPath: embedded) { return embedded }
        return "/usr/local/bin/vbootusb"
    }

    nonisolated static func parseMount(_ output: String) -> String? {
        if let r = output.range(of: "MOUNT:") {
            let rest = output[r.upperBound...]
            let val = rest.prefix(while: { $0 != "\n" && $0 != "\r" })
            let trimmed = String(val).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    nonisolated static func ejectUser(_ dev: StorageDevice) {
        _ = Shell.run("/usr/sbin/diskutil", ["eject", dev.devicePath])
    }

    nonisolated static func runWithAdmin(_ command: String) -> (ok: Bool, output: String) {
        let asEscaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(asEscaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "Could not start: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let combined = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, combined.isEmpty ? "(no output)" : combined)
    }

    nonisolated static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum Theme {
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let indigo = Color(red: 0.36, green: 0.40, blue: 0.95)
    static let flash = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let accent = LinearGradient(colors: [blue, indigo],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct GradientBar: View {
    var value: Double
    var failed: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(failed
                          ? LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
                          : Theme.accent)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 20)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(enabled ? Theme.accent : LinearGradient(colors: [.gray.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .shadow(color: Theme.blue.opacity(enabled ? 0.35 : 0), radius: 10, y: 4)
    }
}

private struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    private var pct: Int { Int((max(0, min(1, model.progress)) * 100).rounded()) }
    private var failed: Bool { model.statusText.hasPrefix("FAILED") }
    private var done: Bool { model.statusText.hasPrefix("DONE") }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                    Color(nsColor: .underPageBackgroundColor)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            RadialGradient(colors: [Theme.blue.opacity(0.18), .clear],
                           center: .top, startRadius: 1, endRadius: 380)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                header
                if model.updateAvailable { updateBanner }
                driveCard
                sourceCard
                optionsCard
                statusCard
                startButton
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear { model.refreshDevices(); model.checkForUpdates() }
        .sheet(isPresented: $model.showResult) {
            ResultView(success: model.resultSuccess, message: model.log) {
                model.showResult = false
            }
        }
        .sheet(isPresented: $model.showAbout) {
            AboutView(model: model) { model.showAbout = false }
        }
    }

    private var updateBanner: some View {
        Button { model.openURL(model.updateURL) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update available — v\(model.latestVersion ?? "")")
                    .fontWeight(.semibold)
                Spacer()
                Text("Download").fontWeight(.bold)
                Image(systemName: "arrow.up.forward")
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "bolt.fill").font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.flash))
                .shadow(color: Theme.blue.opacity(0.4), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("vBootUSB").font(.system(size: 26, weight: .heavy)).tracking(-0.5)
                Text("Bootable USB Creator").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshDevices() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Refresh devices").disabled(model.isBusy)

            Button { model.showAbout = true } label: {
                Image(systemName: "info.circle").font(.system(size: 15, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if model.updateAvailable {
                            Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -2)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .help("About vBootUSB")
        }
        .padding(.bottom, 2)
    }

    private var driveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "USB Drive")
                if model.devices.isEmpty {
                    Label("No USB device found — plug one in and refresh", systemImage: "externaldrive.badge.questionmark")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $model.selectedDeviceID) {
                        ForEach(model.devices) { d in
                            Text("\(d.displayName)  ·  \(d.bsdName)").tag(Optional(d.id))
                        }
                    }
                    .labelsHidden().disabled(model.isBusy)
                    .frame(maxWidth: .infinity)
                }
                if let d = model.selectedDevice, d.requiresExtraConfirmation {
                    Label("External fixed drive (e.g. USB SSD) — double-check the selection.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                FieldLabel(text: "Source")
                Picker("", selection: $model.bootSelection) {
                    ForEach(AppModel.BootSelection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().disabled(model.isBusy)

                if model.needsISO {
                    HStack(spacing: 10) {
                        Image(systemName: "opticaldisc.fill")
                            .foregroundStyle(model.isoPath == nil ? .secondary : Theme.blue)
                        Text(model.isoPath.map { ($0 as NSString).lastPathComponent } ?? "No image selected")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(model.isoPath == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.analyzing { ProgressView().controlSize(.small) }
                        Button("Select…") { model.chooseISO() }
                            .controlSize(.regular).disabled(model.isBusy)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                FieldLabel(text: "Options")
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Partition scheme").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $model.partitionScheme) {
                            ForEach(PartitionScheme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().disabled(model.isBusy)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Target system").font(.caption).foregroundStyle(.secondary)
                        Text(model.partitionScheme.targetSystem)
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                    }
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("File system").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $model.fileSystem) {
                            ForEach(FileSystemType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().disabled(model.isBusy)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Volume label").font(.caption).foregroundStyle(.secondary)
                        TextField("VBOOTUSB", text: $model.volumeLabel)
                            .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    FieldLabel(text: "Status")
                    Spacer()
                    Text("\(pct)%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(failed ? .red : (done ? .green : Theme.blue))
                        .contentTransition(.numericText())
                }
                GradientBar(value: model.progress, failed: failed)
                HStack(spacing: 6) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: done ? "checkmark.circle.fill" : (failed ? "xmark.circle.fill" : "circle.dashed"))
                        .foregroundStyle(done ? .green : (failed ? .red : .secondary)) }
                    Text(model.statusText).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                }
            }
        }
    }

    private var startButton: some View {
        Button(action: { model.start() }) {
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: "bolt.fill") }
                Text(model.isBusy ? "Working…" : "START")
            }
        }
        .buttonStyle(PrimaryButtonStyle(enabled: model.canStart))
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canStart)
    }

}

private struct ResultView: View {
    let success: Bool
    let message: String
    let onClose: () -> Void
    @State private var pop = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(success ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 66, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(success ? .green : .red)
            }
            .scaleEffect(pop ? 1 : 0.5)
            .opacity(pop ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: pop)

            Text(success ? "Done!" : "Failed")
                .font(.system(size: 23, weight: .bold))
            Text(success ? "Your USB drive is ready to boot."
                         : "The operation could not be completed.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !success && !message.isEmpty {
                ScrollView {
                    Text(message).font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 110)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.15)))
            }

            Button(action: onClose) {
                Text("Done")
            }
            .buttonStyle(PrimaryButtonStyle(enabled: true))
            .keyboardShortcut(.defaultAction)
            .padding(.top, 2)
        }
        .padding(28)
        .frame(width: 380)
        .onAppear { pop = true }
    }
}

private struct AboutView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 82, height: 82)
                .overlay(Image(systemName: "bolt.fill").font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.flash))
                .shadow(color: Theme.blue.opacity(0.4), radius: 10, y: 4)

            Text("vBootUSB").font(.system(size: 24, weight: .heavy))
            Text("Version \(model.currentVersion)").font(.callout).foregroundStyle(.secondary)
            Text("Create bootable USB drives for Windows, VMware ESXi and Linux on macOS.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.updateAvailable {
                Button { model.openURL(model.updateURL) } label: {
                    Label("Update to v\(model.latestVersion ?? "")", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle(enabled: true))
            } else {
                Button { model.checkForUpdates(manual: true) } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            HStack(spacing: 18) {
                Button { model.openURL(model.repoURL) } label: {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { model.openURL(model.repoURL + "/issues") } label: {
                    Label("Report an issue", systemImage: "exclamationmark.bubble")
                }
            }
            .font(.caption).buttonStyle(.link)

            Divider().padding(.vertical, 2)
            Text("© 2026 · MIT License").font(.caption2).foregroundStyle(.secondary)

            Button("Close", action: onClose).keyboardShortcut(.cancelAction).padding(.top, 2)
        }
        .padding(28)
        .frame(width: 360)
    }
}
