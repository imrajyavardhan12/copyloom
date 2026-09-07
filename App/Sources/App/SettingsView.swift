import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var newBundleID = ""
  @State private var showingAppPicker = false

  var body: some View {
    TabView {
      ignoredAppsTab
        .tabItem { Label("Ignored Apps", systemImage: "eye.slash") }
      historyTab
        .tabItem { Label("History", systemImage: "clock") }
      permissionsTab
        .tabItem { Label("Permissions", systemImage: "lock.shield") }
    }
    .frame(width: 520, height: 420)
  }

  // MARK: - Ignored apps

  private var ignoredAppsTab: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Copies from these applications are never saved, indexed, or logged.")
        .font(.callout)
        .foregroundStyle(.secondary)

      List {
        ForEach(model.ignoredBundleIdentifiers, id: \.self) { bundleID in
          HStack {
            Image(systemName: "app.badge")
              .foregroundStyle(.secondary)
            Text(bundleID)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            Spacer()
            Button("Remove") {
              model.removeIgnoredBundleID(bundleID)
            }
            .buttonStyle(.link)
          }
        }
        .onDelete { indexSet in
          for index in indexSet {
            model.removeIgnoredBundleID(model.ignoredBundleIdentifiers[index])
          }
        }
      }
      .listStyle(.bordered)

      HStack {
        TextField("com.example.app", text: $newBundleID)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .onSubmit(addManual)
        Button("Add") {
          addManual()
        }
        .disabled(manualCandidate.isEmpty)
        .keyboardShortcut(.defaultAction)
      }

      HStack {
        Button("Add from Running Apps…") {
          showingAppPicker = true
        }
        Spacer()
        Button("Reset to Defaults") {
          model.resetIgnoredToDefaults()
        }
      }
      .buttonStyle(.link)

      if let lastEvent = model.lastEventText {
        Text(lastEvent)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(20)
    .sheet(isPresented: $showingAppPicker) {
      RunningAppsPicker(model: model)
    }
  }

  private var manualCandidate: String {
    newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func addManual() {
    guard !manualCandidate.isEmpty else { return }
    model.addIgnoredBundleID(manualCandidate)
    newBundleID = ""
  }

  // MARK: - History

  private var historyTab: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("History Retention")
          .font(.headline)
        Stepper(
          "Keep history \(model.retentionDays) days",
          value: Binding(
            get: { model.retentionDays },
            set: { model.updateRetentionDays($0) }
          ),
          in: 1...365
        )
        Text("Pinned and favorite clips are never auto-deleted.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("\(model.clipCount) clips stored locally")
          .font(.headline)
        Button("Delete Expired History Now") {
          model.deleteExpiredNow()
        }
        if let lastEvent = model.lastEventText {
          Text(lastEvent)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Permissions

  private var permissionsTab: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(
          systemName: model.automaticPasteEnabled
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(model.automaticPasteEnabled ? .green : .orange)
        .font(.title2)
        VStack(alignment: .leading) {
          Text(
            model.automaticPasteEnabled
              ? "Automatic Paste Enabled" : "Automatic Paste Needs Permission"
          )
          .font(.headline)
          Text(
            model.automaticPasteEnabled
              ? "Enter pastes into the previous app. ⌘Enter always copies only."
              : "Copy works now. Grant Accessibility so Enter can paste."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }

      HStack {
        Button("Refresh Status") {
          model.refreshPermissionStatus()
        }
        Button("Open Accessibility Settings") {
          model.openAccessibilitySettings()
        }
        Button("Enable Automatic Paste…") {
          model.requestAutomaticPastePermission()
        }
        .disabled(model.automaticPasteEnabled)
      }
      .buttonStyle(.link)

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("Running App Identity")
          .font(.headline)
        Text(
          "Ad-hoc development builds change identity on every rebuild. The Accessibility entry must match this exact binary."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Text(model.runningAppPath)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(3)
        Button("Reveal Running App in Finder") {
          model.revealRunningAppInFinder()
        }
        .buttonStyle(.link)
      }

      Spacer()
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      model.refreshPermissionStatus()
    }
  }
}

private struct RunningAppsPicker: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var candidates: [AppModel.RunningAppCandidate] = []
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Add Ignored Application")
          .font(.headline)
        Spacer()
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding()

      TextField("Filter running apps", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal)

      List(filtered) { candidate in
        HStack {
          VStack(alignment: .leading) {
            Text(candidate.displayName)
            Text(candidate.bundleIdentifier)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Button("Ignore") {
            model.addIgnoredBundleID(candidate.bundleIdentifier)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    }
    .frame(width: 480, height: 400)
    .onAppear {
      candidates = model.runningAppCandidates()
    }
  }

  private var filtered: [AppModel.RunningAppCandidate] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return candidates }
    return candidates.filter {
      $0.displayName.lowercased().contains(trimmed)
        || $0.bundleIdentifier.lowercased().contains(trimmed)
    }
  }
}
