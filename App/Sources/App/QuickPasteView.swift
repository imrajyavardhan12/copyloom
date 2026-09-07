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
        .foregroundStyle(.secondary)
      TextField("Search copied text, links, or app:Safari", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 20, weight: .medium))
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
    .padding(.horizontal, 18)
    .frame(height: 58)
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
          LazyVStack(spacing: 5) {
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
          .padding(10)
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
      Text("↑↓ Navigate")
      Text("Return: Paste")
      Text("⌘Return: Copy only")
      Spacer()
      Text("⌘P Pin")
      Text("⌥⌫ Delete")
      Text("⌘1–9")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .frame(height: 36)
  }
}

private struct QuickPasteRow: View {
  let model: QuickPasteModel
  let clip: ClipSummary
  let index: Int
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      if clip.kind == .image {
        ClipThumbnail(model: model, clip: clip, isSelected: isSelected)
      } else {
        Image(systemName: clip.kind == .link ? "link" : "text.alignleft")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(isSelected ? Color.white : Color.accentColor)
          .frame(width: 28, height: 28)
          .background(
            (isSelected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 7)
          )
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(rowTitle)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 6) {
          if let source = clip.source?.applicationName ?? clip.source?.bundleIdentifier {
            Text(source)
          }
          Text(clip.lastSeenAt, style: .relative)
          if clip.copyCount > 1 {
            Text("Copied \(clip.copyCount)×")
          }
        }
        .font(.caption)
        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
      }

      if clip.isPinned {
        Image(systemName: "pin.fill")
          .accessibilityLabel("Pinned")
      }

      if index < 9 {
        Text("⌘\(index + 1)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .foregroundStyle(isSelected ? Color.white : Color.primary)
    .background(
      isSelected ? Color.accentColor : Color.clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
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
    if clip.kind == .image { return "Image from \(source)" }
    return "\(clip.kind == .link ? "Link" : "Text") from \(source): \(clip.text)"
  }
}

/// Lazily loaded image thumbnail. The `.task` starts on appearance and
/// cancels on disappearance, so off-screen rows never decode bytes.
private struct ClipThumbnail: View {
  let model: QuickPasteModel
  let clip: ClipSummary
  let isSelected: Bool

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(isSelected ? Color.white : Color.accentColor)
      }
    }
    .frame(width: 28, height: 28)
    .background(
      (isSelected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.12)),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .task {
      image = await model.loadThumbnail(for: clip)
    }
  }
}
