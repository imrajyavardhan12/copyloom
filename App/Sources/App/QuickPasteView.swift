import AppKit
import ClipDomain
import QuickPasteFeature
import SwiftUI

struct QuickPasteView: View {
  @Bindable var model: QuickPasteModel
  @State private var query = ""
  @State private var searchTask: Task<Void, Never>?
  @FocusState private var searchFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      searchHeader
      Divider()
      results
      Divider()
      footer
    }
    .frame(width: 680, height: 460)
    .background(.ultraThickMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(.separator.opacity(0.7), lineWidth: 1)
    }
    .onAppear {
      searchFocused = true
      Task { await model.loadRecent() }
    }
    .onDisappear {
      searchTask?.cancel()
    }
    .onChange(of: query) { _, newValue in
      searchTask?.cancel()
      searchTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        await model.search(newValue)
      }
    }
  }

  private var searchHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(.tertiary)
      TextField("Search copied text, links, or app:Safari", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 18, weight: .regular))
        .focused($searchFocused)
        .accessibilityLabel("Search clipboard history")
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
    .padding(.horizontal, 20)
    .frame(height: 56)
  }

  @ViewBuilder
  private var results: some View {
    if let errorMessage = model.errorMessage {
      ContentUnavailableView(
        "Search unavailable",
        systemImage: "exclamationmark.magnifyingglass",
        description: Text(errorMessage)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.items.isEmpty && !model.isLoading {
      ContentUnavailableView(
        query.isEmpty ? "No clips yet" : "No matches",
        systemImage: query.isEmpty ? "clipboard" : "magnifyingglass",
        description: Text(
          query.isEmpty
            ? "Enable capture and copy some non-sensitive text."
            : "Try fewer words or a filter such as app:Safari."
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, clip in
              QuickPasteRow(
                model: model,
                clip: clip,
                index: index,
                isSelected: model.selectedIndex == index
              )
              .id(clip.id)
              .contentShape(Rectangle())
              .onTapGesture {
                model.select(index: index)
              }
              .onTapGesture(count: 2) {
                model.select(index: index)
                Task { await model.activateSelected() }
              }
            }
          }
          .padding(8)
        }
        .onChange(of: model.selectedIndex) { _, newIndex in
          guard model.items.indices.contains(newIndex) else { return }
          let scroll = {
            proxy.scrollTo(model.items[newIndex].id, anchor: .center)
          }
          if reduceMotion {
            scroll()
          } else {
            withAnimation(.easeOut(duration: 0.12), scroll)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 16) {
      Text("↵ Paste")
      Text("⌘↵ Copy only")
      if let queued = model.pasteQueue?.count, queued > 0 {
        Text("\(queued) queued · ⌃⌥V pastes next")
          .monospacedDigit()
          .accessibilityLabel(
            "\(queued) \(queued == 1 ? "clip" : "clips") in the Paste Queue. Control-Option-V pastes the next one."
          )
      }
      Spacer()
      Group {
        Text("⇧↵ Queue")
        Text("⌘P Pin")
        Text("⌘F Favorite")
        Text("⌥⌫ Delete")
      }
      .foregroundStyle(.tertiary)
    }
    .font(.system(size: 11.5))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 20)
    .frame(height: 34)
  }
}

private struct QuickPasteRow: View {
  let model: QuickPasteModel
  let clip: ClipSummary
  let index: Int
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      KindBadge(
        clip: clip,
        loadThumbnail: { await model.loadThumbnail(for: clip) },
        isSelected: isSelected
      )

      VStack(alignment: .leading, spacing: 4) {
        Text(rowTitle)
          .font(.system(size: 14, weight: .regular))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 6) {
          if let source = clip.source?.applicationName ?? clip.source?.bundleIdentifier {
            Text(source)
          }
          ClipAgeText(date: clip.lastSeenAt)
          if clip.copyCount > 1 {
            Text("Copied \(clip.copyCount)×")
          }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
      }

      // Flags are monochrome: the glyph shapes already differ, and a lone
      // yellow star would be the only color in the list.
      if clip.isFavorite {
        Image(systemName: "star.fill")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .accessibilityLabel("Favorite")
      }

      if clip.isPinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .accessibilityLabel("Pinned")
      }

      if index < 9 {
        Text("⌘\(index + 1)")
          .font(.system(size: 11.5).monospacedDigit())
          .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.55))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .foregroundStyle(Color.primary)
    .background(
      isSelected ? ClipStyle.selection : Color.clear,
      in: RoundedRectangle(cornerRadius: ClipStyle.rowRadius, style: .continuous)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var rowTitle: String {
    if clip.kind == .image { return "Image" }
    return clip.text.replacingOccurrences(of: "\n", with: " ")
  }

  private var accessibilityLabel: String {
    let source = clip.source?.applicationName ?? clip.source?.bundleIdentifier ?? "unknown app"
    if clip.kind == .image {
      let prefix = clip.isFavorite ? "Favorite " : ""
      return "\(prefix)image from \(source)"
    }
    let prefix = clip.isFavorite ? "Favorite " : ""
    return "\(prefix)\(clip.kind.displayName) from \(source): \(clip.text)"
  }
}
