import AppKit
import ClipDomain
import LibraryFeature
import SwiftUI
import UniformTypeIdentifiers
import os

struct LibraryView: View {
  @Bindable var model: LibraryModel
  @State private var query = ""
  @State private var searchTask: Task<Void, Never>?
  @State private var sheet: LibrarySheet?
  @State private var sheetName = ""
  @State private var sheetQuery = ""

  var body: some View {
    NavigationSplitView {
      List(selection: targetSelection) {
        Section("Library") {
          ForEach(LibrarySection.allCases) { section in
            Label(section.title, systemImage: section.systemImage)
              .tag(LibraryTarget.section(section))
          }
        }
        Section("Collections") {
          ForEach(model.collections) { collection in
            CollectionDropRow(model: model, collection: collection)
          }
          Button("New Collection") {
            sheetName = ""
            sheet = .newCollection
          }
          .buttonStyle(.link)
        }
        Section("Smart Collections") {
          ForEach(model.smartQueries) { smart in
            Label(smart.name, systemImage: "sparkle.magnifyingglass")
              .tag(LibraryTarget.smart(smart.id))
              .contextMenu {
                Button("Rename") {
                  sheetName = smart.name
                  sheet = .renameSmart(smart.id)
                }
                Button("Delete", role: .destructive) {
                  Task { await model.deleteSmartQuery(id: smart.id) }
                }
              }
          }
          Button("New Smart Collection") {
            sheetName = ""
            sheetQuery = ""
            sheet = .newSmart
          }
          .buttonStyle(.link)
        }
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 200)
      .onReceive(NotificationCenter.default.publisher(for: .editCollection)) { note in
        guard let id = note.object as? UUID,
          let collection = model.collections.first(where: { $0.id == id })
        else {
          return
        }
        sheetName = collection.name
        sheet = .renameCollection(id)
      }
      .sheet(item: $sheet) { kind in
        sheetView(kind)
      }
    } content: {
      VStack(spacing: 0) {
        searchHeader
        Divider()
        contentList
      }
      .navigationTitle(model.title)
      .toolbar {
        Menu {
          Button("New Collection") {
            sheetName = ""
            sheet = .newCollection
          }
          Button("New Smart Collection") {
            sheetName = ""
            sheetQuery = ""
            sheet = .newSmart
          }
        } label: {
          Label("New collection", systemImage: "plus")
        }
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
      await model.refreshCollections()
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

  private var targetSelection: Binding<LibraryTarget?> {
    Binding(
      get: {
        if let id = model.activeCollectionID { return .collection(id) }
        if let id = model.activeSmartQueryID { return .smart(id) }
        return .section(model.section)
      },
      set: { target in
        guard let target else { return }
        Task {
          switch target {
          case .section(let section): await model.select(section: section)
          case .collection(let id): await model.selectCollection(id: id)
          case .smart(let id): await model.selectSmart(id: id)
          }
        }
      }
    )
  }

  private var densitySelection: Binding<LibraryDensity> {
    Binding(
      get: { model.density },
      set: { model.setDensity($0) }
    )
  }

  @ViewBuilder
  private func sheetView(_ kind: LibrarySheet) -> some View {
    switch kind {
    case .newCollection:
      FormSheet(title: "New Collection", name: $sheetName) {
        Task {
          await model.createCollection(name: sheetName)
          if model.errorMessage == nil { sheet = nil }
        }
      }
    case .renameCollection(let id):
      FormSheet(title: "Rename Collection", name: $sheetName) {
        Task {
          await model.renameCollection(id: id, name: sheetName)
          if model.errorMessage == nil { sheet = nil }
        }
      }
    case .newSmart:
      SmartSheet(model: model, name: $sheetName, query: $sheetQuery) {
        sheet = nil
      }
    case .renameSmart(let id):
      FormSheet(title: "Rename Smart Collection", name: $sheetName) {
        Task {
          await model.renameSmartQuery(id: id, name: sheetName)
          if model.errorMessage == nil { sheet = nil }
        }
      }
    }
  }
  @ViewBuilder
  private func clipMenu(_ clip: ClipSummary) -> some View {
    Button("Copy") { Task { await copyClip(clip) } }
    Menu("Add to Collection") {
      if model.collections.isEmpty {
        Text("No collections yet")
      }
      ForEach(model.collections) { collection in
        Button(collection.name) {
          Task {
            await model.addToCollection(collectionID: collection.id, clipID: clip.id)
          }
        }
      }
    }
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
      TextField("Search clips", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .accessibilityLabel("Search clips")
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
              .contextMenu {
                clipMenu(clip)
              }
          }
        }
        .padding(12)
      }
    } else {
      List(model.items, id: \.id, selection: itemSelection) { clip in
        LibraryRow(model: model, clip: clip)
          .tag(clip.id)
          .contextMenu {
            clipMenu(clip)
          }
      }
      .listStyle(.inset)
    }
  }

  static func dragProvider(for clip: ClipSummary) -> NSItemProvider {
    ClipDrag.draggedID = clip.id
    let provider = NSItemProvider()
    // External apps receive text only; images resolve through the internal
    // clip-id flavor below (file-URL drag-out stays a follow-up).
    if clip.kind != .image {
      provider.registerObject(NSString(string: clip.text), visibility: .all)
    }
    provider.registerDataRepresentation(
      forTypeIdentifier: ClipDrag.clipIDType, visibility: .ownProcess
    ) { completion in
      completion(Data(clip.id.uuidString.utf8), nil)
      return nil
    }
    return provider
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
      KindBadge(
        clip: clip,
        loadThumbnail: { await model.loadThumbnail(for: clip) },
        isSelected: model.selectedID == clip.id
      )
      VStack(alignment: .leading, spacing: 2) {
        Text(clip.kind == .image ? "Image" : String(clip.text.prefix(120)))
          .font(.system(.body, design: clip.kind == .code ? .monospaced : .default))
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
    .onDrag { LibraryView.dragProvider(for: clip) }
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
      } else if clip.kind == .color, let swatch = Color(hex: clip.text) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(swatch)
          .frame(height: 64)
          .frame(maxWidth: .infinity)
      } else {
        Text(String(clip.text.prefix(200)))
          .font(.system(.body, design: clip.kind == .code ? .monospaced : .default))
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
    .onDrag { LibraryView.dragProvider(for: clip) }
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
            Text(model.title)
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
            if clip.kind == .color, let swatch = Color(hex: clip.text) {
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(swatch)
                .frame(height: 72)
                .frame(maxWidth: .infinity)
            }
            Text(clip.text)
              .font(.system(.body, design: clip.kind == .code ? .monospaced : .default))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Divider()
          metadataRow(
            "Source",
            clip.source?.applicationName ?? clip.source?.bundleIdentifier ?? "Unknown")
          metadataRow("Copied", "\(clip.copyCount)×")
          TagEditor(model: model, clip: clip)
          if clip.kind == .code {
            metadataRow(
              "Lines", "\(clip.text.components(separatedBy: "\n").count)")
          }
          if clip.kind == .file {
            Button("Reveal in Finder") {
              let url = URL(
                fileURLWithPath: (clip.text as NSString).expandingTildeInPath)
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.link)
            .disabled(
              !FileManager.default.fileExists(
                atPath: (clip.text as NSString).expandingTildeInPath))
          }
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

/// Kind icon shared by Library rows. Images resolve thumbnails; colors show
/// a swatch when the value parses as hex (functional notations keep the
/// palette icon until transforms own color conversion in slice 5).
private struct KindBadge: View {
  let clip: ClipSummary
  let loadThumbnail: () async -> NSImage?
  let isSelected: Bool

  var body: some View {
    Group {
      switch clip.kind {
      case .image:
        ClipThumbnail(load: loadThumbnail, isSelected: isSelected)
      case .code:
        badge("chevron.left.forwardslash.chevron.right")
      case .color:
        if let swatch = Color(hex: clip.text) {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(swatch)
            .frame(width: 28, height: 28)
        } else {
          badge("paintpalette")
        }
      case .file:
        badge("doc.fill")
      case .link:
        badge("link")
      case .text:
        badge("text.alignleft")
      }
    }
    .frame(width: 28, height: 28)
  }

  private func badge(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .foregroundStyle(isSelected ? Color.white : Color.accentColor)
      .frame(width: 28, height: 28)
      .background(
        (isSelected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.12)),
        in: RoundedRectangle(cornerRadius: 7)
      )
  }
}

extension Color {
  /// Parses `#rgb`, `#rgba`, `#rrggbb` and `#rrggbbaa` (case-insensitive).
  /// Functional notations are intentionally unsupported here.
  init?(hex: String) {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("#") else { return nil }
    value.removeFirst()
    guard [3, 4, 6, 8].contains(value.count),
      value.allSatisfy(\.isHexDigit)
    else {
      return nil
    }
    if value.count <= 4 {
      value = value.flatMap { [$0, $0] }.map(String.init).joined()
    }
    guard let rgb = UInt64(value.prefix(6), radix: 16) else { return nil }
    let alpha: Double
    if value.count == 8, let byte = UInt64(value.suffix(2), radix: 16) {
      alpha = Double(byte) / 255
    } else {
      alpha = 1
    }
    self.init(
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      opacity: alpha
    )
  }
}

private enum LibrarySheet: Identifiable, Hashable {
  case newCollection
  case renameCollection(UUID)
  case newSmart
  case renameSmart(UUID)

  var id: String {
    switch self {
    case .newCollection: "new-collection"
    case .renameCollection(let id): "rename-collection-\(id.uuidString)"
    case .newSmart: "new-smart"
    case .renameSmart(let id): "rename-smart-\(id.uuidString)"
    }
  }
}

private struct FormSheet: View {
  let title: String
  @Binding var name: String
  let save: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(commit)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 320)
  }

  private func commit() {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    save()
  }
}

private struct SmartSheet: View {
  let model: LibraryModel
  @Binding var name: String
  @Binding var query: String
  let done: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Smart Collection")
        .font(.headline)
      Text(
        "A saved search, re-run every time it opens. Examples: app:Safari, type:image, is:pinned."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
      TextField("Query", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
      if let error = model.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          Task {
            await model.saveSmartQuery(name: name, queryText: query)
            if model.errorMessage == nil { done() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 380)
  }
}

private struct TagEditor: View {
  let model: LibraryModel
  let clip: ClipSummary
  @State private var tags: [ClipTag] = []
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Tags")
        .font(.callout)
        .foregroundStyle(.secondary)
      FlowChips(tags: tags) { tag in
        Task { await remove(tag) }
      }
      TextField("Add tag, comma to commit", text: $draft)
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        .onSubmit(commitDraft)
        .onChange(of: draft) { _, value in
          if value.contains(",") { commitDraft() }
        }
    }
    .task(id: clip.id) {
      tags = await model.tags(for: clip.id)
    }
  }

  private func commitDraft() {
    let names = draft.split(separator: ",").map { String($0) }
    draft = ""
    guard !names.isEmpty else { return }
    Task {
      let current = Set(tags.map(\.normalized))
      let desired = current.union(
        names.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
      await model.setTags(id: clip.id, names: Array(desired))
      tags = await model.tags(for: clip.id)
    }
  }

  private func remove(_ tag: ClipTag) async {
    await model.setTags(
      id: clip.id, names: tags.map(\.normalized).filter { $0 != tag.normalized })
    tags = await model.tags(for: clip.id)
  }
}

private struct FlowChips: View {
  let tags: [ClipTag]
  let remove: (ClipTag) -> Void

  var body: some View {
    FlowLayout {
      ForEach(tags) { tag in
        HStack(spacing: 4) {
          Text(tag.name)
          Button {
            remove(tag)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove tag \(tag.name)")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
      }
    }
  }
}

private struct FlowLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    _ = layout(proposal: .init(width: bounds.width, height: nil), subviews: subviews)
    var point = bounds.origin
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if point.x + size.width > bounds.maxX, point.x > bounds.minX {
        point.x = bounds.minX
        point.y += lineHeight + 6
        lineHeight = 0
      }
      subview.place(at: point, proposal: .unspecified)
      point.x += size.width + 6
      lineHeight = max(lineHeight, size.height)
    }
  }

  private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (
    size: CGSize, rows: Int
  ) {
    var size = CGSize.zero
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var rows = 1
    let maxWidth = proposal.width ?? .infinity
    for subview in subviews {
      let child = subview.sizeThatFits(.unspecified)
      if rowWidth + child.width > maxWidth, rowWidth > 0 {
        size.width = max(size.width, rowWidth)
        size.height += rowHeight + 6
        rowWidth = 0
        rowHeight = 0
        rows += 1
      }
      rowWidth += child.width + 6
      rowHeight = max(rowHeight, child.height)
    }
    size.width = max(size.width, rowWidth)
    size.height += rowHeight
    return (size, rows)
  }
}

private enum ClipDrag {
  static let clipIDType = "io.github.imrajyavardhan12.copyloom.clip-id"

  // Deterministic own-process handoff. NSItemProvider data representations
  // for ad-hoc identifiers proved unreliable at drop time (telemetry showed
  // decode failures with validation passing), so the drag source records
  // the ID here and drops prefer it; the provider stays as fallback.
  // Safe against stale cancels: every new drag overwrites, and only an
  // in-flight drag of ours can reach our own drop target.
  private static let lock = NSLock()
  private static var storedID: UUID?

  static var draggedID: UUID? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedID
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedID = newValue
    }
  }
}

/// Sidebar collection row: full-width drop target with highlight feedback.
/// Uses the closure drop form — the delegate form silently never validated
/// in testing — plus content-free debug telemetry so `log show` reveals the
/// failing stage if drops ever break again.
private struct CollectionDropRow: View {
  let model: LibraryModel
  let collection: ClipCollection
  @State private var isTargeted = false

  var body: some View {
    Label(collection.name, systemImage: "folder")
      .tag(LibraryTarget.collection(collection.id))
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(isTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
      .contextMenu {
        Button("Rename") {
          NotificationCenter.default.post(
            name: .editCollection, object: collection.id)
        }
        Button("Delete", role: .destructive) {
          Task { await model.deleteCollection(id: collection.id) }
        }
      }
      .onDrop(of: [.copyloomClipID], isTargeted: $isTargeted) { providers in
        os_log(
          "library drop-performed count=%d", log: .libraryDrop, type: .default,
          Int32(providers.count))
        if let dragged = ClipDrag.draggedID {
          ClipDrag.draggedID = nil
          os_log("library drop-handoff", log: .libraryDrop, type: .default)
          Task { @MainActor in
            await model.addToCollection(collectionID: collection.id, clipID: dragged)
          }
          return true
        }
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: ClipDrag.clipIDType) {
          data, _ in
          guard let data,
            let string = String(data: data, encoding: .utf8),
            let clipID = UUID(uuidString: string)
          else {
            os_log("library drop-decode-failed", log: .libraryDrop, type: .default)
            return
          }
          os_log("library drop-loaded", log: .libraryDrop, type: .default)
          Task { @MainActor in
            await model.addToCollection(collectionID: collection.id, clipID: clipID)
          }
        }
        return true
      }
  }
}

extension UTType {
  /// Own-process clip reference. Must use `exportedAs`: `UTType(_:)` only
  /// resolves declared identifiers and returns nil for ad-hoc strings,
  /// which silently broke drop validation (provider promised a string the
  /// validator never matched). Exporting declares it at runtime.
  static var copyloomClipID: UTType {
    UTType(exportedAs: ClipDrag.clipIDType, conformingTo: .data)
  }
}

extension OSLog {
  fileprivate static let libraryDrop = OSLog(
    subsystem: "io.github.imrajyavardhan12.copyloom", category: "LibraryDrop")
}

extension Notification.Name {
  fileprivate static let editCollection = Notification.Name(
    "io.github.imrajyavardhan12.copyloom.editCollection")
}
