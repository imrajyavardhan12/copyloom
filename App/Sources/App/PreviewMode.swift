#if DEBUG
  import AppKit
  import ClipArchive
  import ClipDomain
  import LibraryFeature
  import QuickPasteFeature
  import SwiftUI

  /// Developer-only visual preview (`COPYLOOM_PREVIEW=1`).
  ///
  /// Runs the app against a separate database seeded with synthetic clips,
  /// renders the main surfaces to PNG in-process (no Screen Recording
  /// permission, no real history on screen), and quits. It never touches the
  /// real database, never starts clipboard capture, and does not exist in
  /// release builds.
  ///
  ///     COPYLOOM_PREVIEW=1 Copyloom.app/Contents/MacOS/Copyloom
  ///
  /// PNGs land in the sandbox container's temporary directory; the path is
  /// printed to stderr.
  @MainActor
  enum PreviewMode {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["COPYLOOM_PREVIEW"] == "1"
    }

    static let dataDirectoryName = "Copyloom-Preview"

    static func launch(
      model: AppModel,
      repository: any ClipRepository,
      libraryModel: LibraryModel
    ) {
      Task { @MainActor in
        do {
          if try await repository.count() == 0 {
            try await PreviewFixtures.seed(into: repository)
          }
          // Give the background OCR queue a moment to index seeded images.
          try? await Task.sleep(for: .seconds(8))
          let output = FileManager.default.temporaryDirectory
          log("preview output: \(output.path)")
          await exportCheck(libraryModel: libraryModel, into: output)
          for scheme in ["light", "dark"] {
            await PreviewSnapshots.renderAll(
              scheme: scheme, model: model, repository: repository,
              libraryModel: libraryModel, into: output)
          }
          log("preview done")
        } catch {
          log("preview failed: \(error)")
        }
        NSApp.terminate(nil)
      }
    }

    /// Runs a real export through the app's own `LibraryModel` (so through the
    /// production wiring and privacy gate), then verifies the result and
    /// checks that the planted fake credential never reached the archive.
    private static func exportCheck(libraryModel: LibraryModel, into directory: URL) async {
      let destination = directory.appending(
        path: "PreviewExport-\(UUID().uuidString)", directoryHint: .isDirectory)
      await libraryModel.exportLibrary(to: destination)
      guard case .finished(let summary, _) = libraryModel.exportState else {
        log("export check FAILED: state \(libraryModel.exportState)")
        return
      }
      log(
        "export: clips=\(summary.clips) images=\(summary.attachments) "
          + "skippedSensitive=\(summary.skippedSensitive) "
          + "skippedQuarantined=\(summary.skippedQuarantinedImages) "
          + "skippedMissing=\(summary.skippedMissingAttachments)")
      do {
        let verified = try ArchiveVerifier().verify(at: destination)
        var read = 0
        try ArchiveReader(archive: verified).forEachClip { _, result in
          _ = try result.get()
          read += 1
        }
        let marker = Data(PreviewFixtures.plantedCredential.utf8)
        var leaked = false
        for path in try FileManager.default.subpathsOfDirectory(atPath: destination.path) {
          let url = destination.appending(path: path)
          guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
          else { continue }
          if try Data(contentsOf: url).range(of: marker) != nil { leaked = true }
        }
        log(
          "export verified: records=\(read) unlisted=\(verified.unlistedFiles.count) credentialInArchive=\(leaked)"
        )
      } catch {
        log("export check FAILED: verification threw \(error)")
      }
      libraryModel.dismissExportResult()
    }

    static func log(_ message: String) {
      FileHandle.standardError.write(Data((message + "\n").utf8))
    }
  }

  @MainActor
  enum PreviewSnapshots {
    static func renderAll(
      scheme: String,
      model: AppModel,
      repository: any ClipRepository,
      libraryModel: LibraryModel,
      into directory: URL
    ) async {
      let appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)

      // Library, list density, first text clip selected.
      await libraryModel.select(section: .history)
      await libraryModel.refreshCollections()
      libraryModel.setDensity(.list)
      if let first = libraryModel.items.first(where: { $0.kind == .text }) {
        libraryModel.select(id: first.id)
      }
      await render(
        LibraryView(model: libraryModel), size: CGSize(width: 1100, height: 700),
        name: "library-list-\(scheme)", appearance: appearance, in: directory)

      // Library, cards density.
      libraryModel.setDensity(.cards)
      await render(
        LibraryView(model: libraryModel), size: CGSize(width: 1100, height: 700),
        name: "library-cards-\(scheme)", appearance: appearance, in: directory)
      libraryModel.setDensity(.list)

      // JSON clip with the transform preview open.
      await libraryModel.select(section: .code)
      if let json = libraryModel.items.first(where: { $0.text.hasPrefix("{") }) {
        libraryModel.select(id: json.id)
        libraryModel.previewTransform(id: "json.pretty")
      }
      await render(
        LibraryView(model: libraryModel), size: CGSize(width: 1100, height: 700),
        name: "library-transform-\(scheme)", appearance: appearance, in: directory)
      libraryModel.dismissTransformPreview()

      // Image clip.
      await libraryModel.select(section: .images)
      if let image = libraryModel.items.first { libraryModel.select(id: image.id) }
      await render(
        LibraryView(model: libraryModel), size: CGSize(width: 1100, height: 700),
        name: "library-image-\(scheme)", appearance: appearance, in: directory)

      // Colors section.
      await libraryModel.select(section: .colors)
      if let color = libraryModel.items.first { libraryModel.select(id: color.id) }
      await render(
        LibraryView(model: libraryModel), size: CGSize(width: 1100, height: 700),
        name: "library-colors-\(scheme)", appearance: appearance, in: directory)

      // Empty state.
      await libraryModel.select(section: .favorites)
      for clip in libraryModel.items { await libraryModel.toggleFavorite(id: clip.id) }
      await render(
        LibraryView(model: libraryModel), size: CGSize(width: 1100, height: 700),
        name: "library-empty-\(scheme)", appearance: appearance, in: directory)
      await libraryModel.select(section: .history)

      // Quick Paste.
      let quickPaste = QuickPasteModel(repository: repository, delivery: PreviewDelivery())
      await quickPaste.loadRecent()
      await render(
        QuickPasteView(model: quickPaste), size: CGSize(width: 680, height: 460),
        name: "quickpaste-\(scheme)", appearance: appearance, paintsBackground: false,
        in: directory)

      // Settings.
      await render(
        SettingsView(model: model), size: CGSize(width: 520, height: 520),
        name: "settings-\(scheme)", appearance: appearance, in: directory)
    }

    private static func render<Content: View>(
      _ view: Content,
      size: CGSize,
      name: String,
      appearance: NSAppearance?,
      paintsBackground: Bool = true,
      in directory: URL
    ) async {
      let framed = view.frame(width: size.width, height: size.height)
      let host = NSHostingView(
        rootView: framed.background(
          paintsBackground ? Color(nsColor: .windowBackgroundColor) : Color.clear))
      host.frame = CGRect(origin: .zero, size: size)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.appearance = appearance
      window.contentView = host
      window.titlebarAppearsTransparent = true
      window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
      window.orderFrontRegardless()
      // Let `.task` loaders, thumbnails and layout settle.
      try? await Task.sleep(for: .milliseconds(900))
      host.layoutSubtreeIfNeeded()
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        PreviewMode.log("snapshot failed (no bitmap): \(name)")
        window.orderOut(nil)
        return
      }
      host.cacheDisplay(in: host.bounds, to: rep)
      window.orderOut(nil)
      guard let png = rep.representation(using: .png, properties: [:]) else {
        PreviewMode.log("snapshot failed (no png): \(name)")
        return
      }
      let url = directory.appending(path: "\(name).png")
      do {
        try png.write(to: url)
        PreviewMode.log("wrote \(url.lastPathComponent)")
      } catch {
        PreviewMode.log("snapshot write failed: \(name): \(error)")
      }
    }
  }

  @MainActor
  private final class PreviewDelivery: ClipDelivering {
    func deliver(_ clip: ClipSummary, mode: ClipDeliveryMode) async throws {}
  }

  /// Synthetic, obviously fake library content. Nothing here is real data.
  enum PreviewFixtures {
    private struct App {
      let bundleID: String
      let name: String
      var source: ClipSource {
        ClipSource(bundleIdentifier: bundleID, applicationName: name, provenance: .declared)
      }
    }

    private static let safari = App(bundleID: "com.apple.Safari", name: "Safari")
    private static let xcode = App(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    private static let notes = App(bundleID: "com.apple.Notes", name: "Notes")
    private static let terminal = App(bundleID: "com.apple.Terminal", name: "Terminal")
    private static let figma = App(bundleID: "com.figma.Desktop", name: "Figma")
    private static let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    private static let finder = App(bundleID: "com.apple.finder", name: "Finder")

    /// An obviously fake credential stored directly (bypassing capture) so the
    /// export check can prove the gate re-screens stored text.
    static let plantedCredential = "DATABASE_PASSWORD=correct-horse-battery-staple"

    @MainActor
    static func seed(into repository: any ClipRepository) async throws {
      let now = Date()
      func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

      struct Seed {
        let kind: ClipKind
        let text: String
        let app: App
        let minutesAgo: Double
        var pinned = false
        var favorite = false
        var tags: [String] = []
        var collection: String?
      }

      let seeds: [Seed] = [
        Seed(
          kind: .text,
          text:
            "Reminder: review the Q4 roadmap draft before Thursday's sync with design, and flag anything that depends on the new onboarding flow.",
          app: notes, minutesAgo: 4, favorite: true, tags: ["work"], collection: "Project Atlas"),
        Seed(
          kind: .link,
          text: "https://developer.apple.com/documentation/swiftui/navigationsplitview",
          app: safari, minutesAgo: 11, pinned: true, tags: ["reference"],
          collection: "Reading list"),
        Seed(
          kind: .code,
          text:
            #"{"user":{"id":4821,"name":"Ada Lovelace","roles":["admin","editor"]},"active":true,"plan":"team","seats":12}"#,
          app: xcode, minutesAgo: 19, tags: ["work"], collection: "Project Atlas"),
        Seed(
          kind: .color, text: "#3B82F6", app: figma, minutesAgo: 27, favorite: true,
          tags: ["design"], collection: "Project Atlas"),
        Seed(
          kind: .code,
          text: """
            func greeting(for name: String) -> String {
              let trimmed = name.trimmingCharacters(in: .whitespaces)
              return trimmed.isEmpty ? "Hello!" : "Hello, \\(trimmed)!"
            }
            """, app: xcode, minutesAgo: 41, tags: ["work"]),
        Seed(
          kind: .link, text: "https://www.figma.com/file/abc123/Atlas-Design-System",
          app: figma, minutesAgo: 55, tags: ["design"], collection: "Project Atlas"),
        Seed(
          kind: .text, text: "221B Baker Street, London NW1 6XE", app: safari, minutesAgo: 73),
        Seed(
          kind: .code, text: "git log --oneline --graph --decorate -20", app: terminal,
          minutesAgo: 96, pinned: true),
        Seed(kind: .color, text: "rgb(255, 99, 71)", app: figma, minutesAgo: 130, tags: ["design"]),
        Seed(
          kind: .file, text: "/Users/demo/Documents/Roadmap-Q4.pdf", app: finder,
          minutesAgo: 160, collection: "Project Atlas"),
        Seed(
          kind: .text,
          text: """
            Standup notes
            - Shipped the export design for review
            - Blocked on API rate limits (waiting on infra)
            - Next: onboarding copy pass with Priya
            """, app: notes, minutesAgo: 190, favorite: true, tags: ["work"]),
        Seed(
          kind: .link, text: "https://swift.org/blog/swift-6-concurrency/", app: safari,
          minutesAgo: 240, tags: ["reference"], collection: "Reading list"),
        Seed(
          kind: .text, text: "Can we move the design review to 3pm? Priya is out until then.",
          app: slack, minutesAgo: 300),
        Seed(kind: .color, text: "hsl(262, 83%, 58%)", app: figma, minutesAgo: 380),
        Seed(
          kind: .code, text: "SELECT id, name FROM clips WHERE is_pinned = 1 ORDER BY id DESC;",
          app: terminal, minutesAgo: 470),
        Seed(
          kind: .text,
          text:
            "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.",
          app: notes, minutesAgo: 600),
        Seed(kind: .text, text: plantedCredential, app: terminal, minutesAgo: 900),
      ]

      var collections: [String: UUID] = [:]
      for name in ["Project Atlas", "Reading list"] {
        collections[name] = try await repository.createCollection(name: name, at: now).id
      }

      for seed in seeds {
        let summary = try await repository.saveAcceptedText(
          AcceptedTextClip(
            id: UUID(), kind: seed.kind, text: seed.text, capturedAt: ago(seed.minutesAgo),
            source: seed.app.source))
        if seed.pinned { try await repository.setPinned(id: summary.id, isPinned: true) }
        if seed.favorite { try await repository.setFavorite(id: summary.id, isFavorite: true) }
        for tag in seed.tags { try await repository.tagClip(id: summary.id, tag: tag) }
        if let name = seed.collection, let collectionID = collections[name] {
          try await repository.addToCollection(
            collectionID: collectionID, clipID: summary.id, at: now)
        }
      }

      let images: [(String, String, NSColor, NSColor, Double)] = [
        ("Q4 Roadmap", "Atlas milestones and owners", .systemIndigo, .systemTeal, 33),
        ("Onboarding Flow", "Welcome screen v3", .systemOrange, .systemPink, 210),
        ("Revenue Dashboard", "Weekly active teams", .systemGreen, .systemBlue, 420),
      ]
      for (title, subtitle, start, end, minutes) in images {
        guard
          let data = makeImage(
            title: title, subtitle: subtitle, from: start, to: end,
            size: CGSize(width: 960, height: 600))
        else { continue }
        let summary = try await repository.saveAcceptedImage(
          AcceptedImageClip(
            id: UUID(), data: data, uti: "public.png", width: 960, height: 600,
            capturedAt: ago(minutes), source: safari.source))
        if title == "Q4 Roadmap", let collectionID = collections["Project Atlas"] {
          try await repository.addToCollection(
            collectionID: collectionID, clipID: summary.id, at: now)
        }
      }

      _ = try await repository.saveQuery(name: "Code snippets", queryText: "type:code", at: now)
      _ = try await repository.saveQuery(name: "From Safari", queryText: "app:Safari", at: now)
    }

    @MainActor
    private static func makeImage(
      title: String, subtitle: String, from start: NSColor, to end: NSColor, size: CGSize
    ) -> Data? {
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
      else { return nil }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      NSGradient(starting: start, ending: end)?
        .draw(in: CGRect(origin: .zero, size: size), angle: 35)
      let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white,
      ]
      let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 36, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
      ]
      NSAttributedString(string: title, attributes: titleAttributes)
        .draw(at: CGPoint(x: 64, y: size.height / 2))
      NSAttributedString(string: subtitle, attributes: subtitleAttributes)
        .draw(at: CGPoint(x: 64, y: size.height / 2 - 64))
      NSGraphicsContext.restoreGraphicsState()
      return rep.representation(using: .png, properties: [:])
    }
  }
#endif
