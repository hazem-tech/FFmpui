//
//  ContentView.swift
//  FFmpui
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var compressor = VideoCompressor()
    @State private var confirmReplace = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !compressor.missingTools.isEmpty {
                MissingToolsBanner(missing: compressor.missingTools) {
                    compressor.refreshToolCheck()
                }
            }

            HStack {
                Button("Add Videos…", systemImage: "film.stack") { pickVideos() }
                Button("Add Folder…", systemImage: "folder") { pickFolder() }
                Spacer()
                Button("Clear", systemImage: "trash") { compressor.clear() }
                    .disabled(compressor.isRunning || compressor.items.isEmpty)
            }
            .controlSize(.large)

            fileList

            options
                .disabled(compressor.isRunning)

            if !compressor.log.isEmpty {
                LogView(lines: compressor.log)
            }

            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                Spacer()
                if compressor.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { compressor.stop() }
                        .controlSize(.large)
                } else {
                    Button("Start", systemImage: "play.fill") { compressor.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!compressor.canStart)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 600)
        // Asked when the switch is turned on, not on every Start; the choice
        // is remembered.
        .confirmationDialog("Replace original files?", isPresented: $confirmReplace) {
            Button("Replace Originals", role: .destructive) { compressor.replaceOriginals = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From now on, each original video is overwritten by its compressed version, once the compressed file has been checked. This can't be undone.")
        }
    }

    // MARK: - Pieces

    private var options: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mode", selection: $compressor.mode) {
                ForEach(VideoCompressor.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            caption(compressor.mode.caption)

            Picker("Scale", selection: $compressor.scale) {
                ForEach(OutputScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.top, 6)
            caption(scaleCaption)

            Toggle("Replace original files", isOn: replaceBinding)
                .padding(.top, 6)
            caption(compressor.replaceOriginals
                    ? "The original videos are overwritten with the compressed versions."
                    : "Originals are kept. Compressed videos are saved next to them as “name_copy”.")

            if compressor.mode.usesCPUEncoder {
                Toggle("High priority", isOn: $compressor.highPriority)
                    .padding(.top, 6)
                caption(compressor.highPriority
                        ? "Uses all of the Mac's power, as fast as running the script in Terminal."
                        : "Runs on the efficiency cores only: the Mac stays cool and quiet, but compressing takes much longer.")
            }
        }
    }

    private var scaleCaption: String {
        switch compressor.scale {
        case .full: "Same width and height as the original."
        case .half: "Half the width and height."
        case .quarter: "A quarter of the width and height."
        }
    }

    /// Turning Replace on asks first; turning it off doesn't.
    private var replaceBinding: Binding<Bool> {
        Binding {
            compressor.replaceOriginals
        } set: { isOn in
            if isOn {
                confirmReplace = true
            } else {
                compressor.replaceOriginals = false
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FFmpui")
                .font(.largeTitle.bold())
            Text("Compress videos to HEVC and keep all of their metadata.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var fileList: some View {
        Group {
            if compressor.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Drop videos or folders here")
                        .font(.headline)
                    Text("MP4, MOV and M4V")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                )
            } else {
                List(compressor.items) { item in
                    VideoRow(item: item, canRemove: item.status != .working) {
                        compressor.remove(item)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            compressor.add(urls: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var summary: String {
        let items = compressor.items
        guard !items.isEmpty else { return "No videos added" }
        let done = items.filter { $0.status == .done }
        let failed = items.filter { if case .failed = $0.status { true } else { false } }.count
        var text = "\(done.count) of \(items.count) done"
        if failed > 0 { text += " · \(failed) failed" }
        let before = done.compactMap(\.originalSize).reduce(0, +)
        let after = done.compactMap(\.newSize).reduce(0, +)
        if before > 0 && after < before {
            text += " · saved \((before - after).formatted(.byteCount(style: .file)))"
        }
        return text
    }

    // MARK: - Pickers

    private func pickVideos() {
        let panel = NSOpenPanel()
        panel.title = "Choose Videos"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = VideoCompressor.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            compressor.add(urls: panel.urls)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "All MP4 / MOV / M4V videos in this folder and its subfolders will be added."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            compressor.add(urls: panel.urls)
        }
    }
}

// MARK: - Row

private struct VideoRow: View {
    let item: VideoItem
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.status == .working {
                    if let phase = item.phase, phase.hasPrefix("Finding") {
                        // Quality search: no meaningful percentage yet.
                        ProgressView(phase + "…")
                            .progressViewStyle(.linear)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                    }
                } else {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsError ? .red : .secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if item.status == .done, let output = item.outputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from list")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var detailIsError: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var detail: String {
        switch item.status {
        case .waiting:
            return item.url.deletingLastPathComponent().path
        case .working:
            return ""
        case .done:
            guard let before = item.originalSize, let after = item.newSize else { return "Done" }
            let percent = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            let sizes = "\(before.formatted(.byteCount(style: .file))) → \(after.formatted(.byteCount(style: .file)))"
            return percent > 0 ? "\(sizes) (−\(percent)%)" : sizes
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - Missing tools

private struct MissingToolsBanner: View {
    let missing: [String]
    let onRecheck: () -> Void

    private let command = "brew install ffmpeg"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Missing: \(missing.joined(separator: ", "))")
                    .font(.headline)
                Text("Install them with Homebrew in Terminal, then click Check Again:")
                    .font(.callout)
                HStack {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                    Button("Check Again", action: onRecheck)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Log

private struct LogView: View {
    let lines: [String]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Details", isExpanded: $isExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(height: 120)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: lines.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .font(.callout)
    }
}

#Preview {
    ContentView()
}
