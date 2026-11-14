//
//  ContentView.swift
//  FFmpui (iOS)
//

import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var compressor = PhotoCompressor()
    @State private var selection: [PhotosPickerItem] = []
    @State private var confirmReplace = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if compressor.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(compressor.items) { item in
                            PhotoRow(item: item)
                                .swipeActions {
                                    if !item.isBusy {
                                        Button("Remove", systemImage: "trash", role: .destructive) {
                                            compressor.remove(item)
                                        }
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .safeAreaInset(edge: .top) {
                if !compressor.hasFullAccess {
                    AccessBanner(compressor: compressor)
                        .padding(.horizontal)
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("FFmpui")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", systemImage: "trash") { compressor.clear() }
                        .disabled(compressor.isRunning || compressor.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                        Label("Add Videos", systemImage: "plus")
                    }
                    .disabled(!compressor.hasFullAccess)
                }
            }
            .onChange(of: selection) {
                guard !selection.isEmpty else { return }
                compressor.add(assetIDs: selection.compactMap(\.itemIdentifier))
                selection = []
            }
            .confirmationDialog(
                "Replace \(compressor.pendingCount) original video\(compressor.pendingCount == 1 ? "" : "s")?",
                isPresented: $confirmReplace,
                titleVisibility: .visible
            ) {
                Button("Replace Originals", role: .destructive) { compressor.start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each original is only deleted after its compressed copy has been checked and saved. iOS asks you to confirm, and the originals stay in Recently Deleted for 30 days.")
            }
        }
        .task {
            if PhotoLibrary.authorization == .notDetermined {
                await compressor.requestAccess()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { compressor.refreshAccess() }
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Videos", systemImage: "film.stack")
        } description: {
            Text("Add videos from your library. They're compressed to HEVC and keep their date, location and camera details.")
        } actions: {
            PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                Text("Add Videos")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!compressor.hasFullAccess)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Replace originals", isOn: $compressor.replaceOriginals)
                .disabled(compressor.isRunning)
            Text(compressor.replaceOriginals
                 ? "Originals are moved to Recently Deleted after their compressed copies are saved."
                 : "Originals are kept. Compressed videos are added to your library as “name_copy”.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("High priority", isOn: $compressor.highPriority)
                .disabled(compressor.isRunning)

            if !compressor.log.isEmpty {
                LogView(lines: compressor.log)
            }

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if compressor.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { compressor.stop() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start", systemImage: "play.fill") {
                        if compressor.replaceOriginals {
                            confirmReplace = true
                        } else {
                            compressor.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!compressor.canStart)
                }
            }
            .controlSize(.large)
        }
        .padding()
        .background(.bar)
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
}

// MARK: - Row

private struct PhotoRow: View {
    let item: PhotoItem
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    statusIcon
                    Text(item.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                switch item.status {
                case .downloading, .working:
                    ProgressView(value: item.progress) {
                        Text(item.status == .downloading ? "Reading original…" : "Compressing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .saving:
                    Text("Saving to Photos…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsError ? .red : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: item.assetID) {
            thumbnail = await PhotoLibrary.thumbnail(id: item.assetID, side: 156)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading, .working, .saving:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "forward.fill").foregroundStyle(.secondary)
        }
    }

    private var detailIsError: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var detail: String {
        switch item.status {
        case .waiting:
            return "Waiting"
        case .downloading, .working, .saving:
            return ""
        case .done:
            guard let before = item.originalSize, let after = item.newSize else { return "Done" }
            let percent = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            let sizes = "\(before.formatted(.byteCount(style: .file))) → \(after.formatted(.byteCount(style: .file)))"
            return percent > 0 ? "\(sizes) (−\(percent)%)" : sizes
        case .failed(let reason):
            return reason
        case .skipped(let reason):
            return "Skipped: \(reason)"
        }
    }
}

// MARK: - Photos access

private struct AccessBanner: View {
    let compressor: PhotoCompressor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Full Photos access needed")
                    .font(.headline)
                Text("FFmpui reads each video's original file and saves the compressed copy back to your library. Choose “Full Access” for Photos.")
                    .font(.callout)
                if PhotoLibrary.authorization == .notDetermined {
                    Button("Allow Access") { Task { await compressor.requestAccess() } }
                        .buttonStyle(.bordered)
                } else {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
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
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(height: 140)
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
