import AppKit
import ClipDomain
import LibraryFeature
import SwiftUI

struct LibraryView: View {
  @Bindable var model: LibraryModel
  @State private var query = ""
  @State private var searchTask: Task<Void, Never>?

  var body: some View {
    NavigationSplitView {
      List(selection: sectionSelection) {
        ForEach(LibrarySection.allCases) { section in
          Label(section.title, systemImage: section.systemImage)
            .tag(section)
        }
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 190)
    } content: {
      VStack(spacing: 0) {
        searchHeader
        Divider()
        contentList
      }
      .navigationTitle(model.section.title)
      .toolbar {
        Picker("Density", selection: densitySelection) {
          Text("List").tag(LibraryDensity.list)
          Text("Cards").tag(LibraryDensity.cards)
        }
        .pickerStyle(.segmented)
      }
    } detail: {
      InspectorView(model: model)
    }
    .task {
      await model.refresh()
    }
    .onDisappear {
      searchTask?.cancel()
    }
    .onChange(of: query) { _, newValue in
      searchTask?.cancel()
      searchTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        await model.search(newValue)
      }
    }
  }

  private var sectionSelection: Binding<LibrarySection?> {
    Binding(
      get: { model.section },
      set: { section in
        guard let section else { return }
        Task { await model.select(section: section) }
      }
    )
  }

  private var densitySelection: Binding<LibraryDensity> {
    Binding(
      get: { model.density },
      set: { model.setDensity($0) }
    )
  }

  private var itemSelection: Binding<UUID?> {
    Binding(
      get: { model.selectedID },
      set: { model.select(id: $0) }
    )
  }

  private var searchHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search \(model.section.title.lowercased())", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .accessibilityLabel("Search \(model.section.title)")
      if model.isLoading {
        ProgressView()
          .controlSize(.small)
      } else if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
  }

  @FocusState private var searchFocused: Bool

  @ViewBuilder
  private var contentList: some View {
    if let errorMessage = model.errorMessage {
      ContentUnavailableView(
        "Library unavailable",
        systemImage: "exclamationmark.magnifyingglass",
        description: Text(errorMessage)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.items.isEmpty && !model.isLoading {
      ContentUnavailableView(
        query.isEmpty ? "No clips here yet" : "No matches",
        systemImage: query.isEmpty ? "clipboard" : "magnifyingglass",
        description: Text(
          query.isEmpty
            ? "Copied items appear here automatically."
            : "Try fewer words or a filter such as app:Safari."
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.density == .cards {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
          spacing: 10
        ) {
          ForEach(model.items) { clip in
            LibraryCard(model: model, clip: clip, isSelected: model.selectedID == clip.id)
              .onTapGesture { model.select(id: clip.id) }
              .onTapGesture(count: 2) { model.select(id: clip.id) }
          }
        }
        .padding(12)
      }
    } else {
      List(model.items, id: \.id, selection: itemSelection) { clip in
        LibraryRow(model: model, clip: clip)
          .tag(clip.id)
          .contextMenu {
            Button("Copy") { Task { await copyClip(clip) } }
            Button(clip.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
              Task { await model.toggleFavorite(id: clip.id) }
            }
            Button(clip.isPinned ? "Unpin" : "Pin") {
              Task { await model.togglePin(id: clip.id) }
            }
            Divider()
            Button("Delete", role: .destructive) {
              Task { await model.delete(id: clip.id) }
            }
          }
      }
      .listStyle(.inset)
    }
  }

  private func copyClip(_ clip: ClipSummary) async {
    let copier = PasteboardClipCopier()
    do {
      if clip.kind == .image {
        guard let data = await model.imageData(for: clip.id),
          let meta = try? await model.attachmentMeta(for: clip.id)
        else {
          return
        }
        try copier.copyImage(
          data, uti: meta.uti, sourceBundleID: clip.source?.bundleIdentifier)
      } else {
        try copier.copy(clip)
      }
    } catch {
      // Copy failures stay silent here; the inspector surfaces them.
    }
  }
}

private struct LibraryRow: View {
  let model: LibraryModel
  let clip: ClipSummary

  var body: some View {
    HStack(spacing: 10) {
      if clip.kind == .image {
        ClipThumbnail(
          load: { await model.loadThumbnail(for: clip) },
          isSelected: model.selectedID == clip.id
        )
      } else {
        Image(systemName: clip.kind == .link ? "link" : "text.alignleft")
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(clip.kind == .image ? "Image" : String(clip.text.prefix(120)))
          .lineLimit(2)
        HStack(spacing: 6) {
          if let source = clip.source?.applicationName ?? clip.source?.bundleIdentifier {
            Text(source)
          }
          Text(clip.lastSeenAt, style: .relative)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if clip.isFavorite {
        Image(systemName: "star.fill")
          .foregroundStyle(.yellow)
          .accessibilityLabel("Favorite")
      }
      if clip.isPinned {
        Image(systemName: "pin.fill")
          .foregroundStyle(.secondary)
          .accessibilityLabel("Pinned")
      }
    }
    .padding(.vertical, 4)
  }
}

private struct LibraryCard: View {
  let model: LibraryModel
  let clip: ClipSummary
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if clip.kind == .image {
        ClipThumbnail(
          load: { await model.loadThumbnail(for: clip) },
          isSelected: model.selectedID == clip.id
        )
        .frame(maxWidth: .infinity)
      } else {
        Text(String(clip.text.prefix(200)))
          .font(.body)
          .lineLimit(6, reservesSpace: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        if let source = clip.source?.applicationName ?? clip.source?.bundleIdentifier {
          Text(source)
        }
        Spacer()
        if clip.isFavorite {
          Image(systemName: "star.fill").foregroundStyle(.yellow)
        }
        if clip.isPinned {
          Image(systemName: "pin.fill").foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(
      isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5),
          lineWidth: 1)
    }
  }
}

private struct InspectorView: View {
  let model: LibraryModel
  @State private var copyError = false

  var body: some View {
    if let clip = model.selectedClip {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(model.section.title)
              .font(.headline)
            Spacer()
            Button(clip.isFavorite ? "Unfavorite" : "Favorite") {
              Task { await model.toggleFavorite(id: clip.id) }
            }
            .buttonStyle(.link)
            Button(clip.isPinned ? "Unpin" : "Pin") {
              Task {
                await model.togglePin(id: clip.id)
              }
            }
            .buttonStyle(.link)
          }
          if clip.kind == .image {
            ClipThumbnail(
              load: { await model.loadThumbnail(for: clip) },
              isSelected: model.selectedID == clip.id
            )
            .frame(maxWidth: .infinity)
          } else {
            Text(clip.text)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Divider()
          metadataRow(
            "Source",
            clip.source?.applicationName ?? clip.source?.bundleIdentifier ?? "Unknown")
          metadataRow("Copied", "\(clip.copyCount)×")
          metadataRow("First seen", clip.createdAt.formatted())
          metadataRow("Last seen", clip.lastSeenAt.formatted())
          Divider()
          HStack {
            Button("Copy") { Task { await copyClip(clip) } }
              .buttonStyle(.borderedProminent)
            Button("Delete", role: .destructive) {
              Task { await model.delete(id: clip.id) }
            }
          }
          if copyError {
            Text("Copy failed.")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
        .padding(16)
      }
    } else {
      ContentUnavailableView(
        "No selection",
        systemImage: "sidebar.right",
        description: Text("Select a clip to preview it.")
      )
    }
  }

  private func metadataRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .textSelection(.enabled)
    }
    .font(.callout)
  }

  private func copyClip(_ clip: ClipSummary) async {
    copyError = false
    let copier = PasteboardClipCopier()
    do {
      if clip.kind == .image {
        guard let data = await model.imageData(for: clip.id),
          let meta = try? await model.attachmentMeta(for: clip.id)
        else {
          copyError = true
          return
        }
        try copier.copyImage(
          data, uti: meta.uti, sourceBundleID: clip.source?.bundleIdentifier)
      } else {
        try copier.copy(clip)
      }
    } catch {
      copyError = true
    }
  }
}
