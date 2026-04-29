import SwiftUI

struct SettingsView: View {
    @AppStorage("username")             private var username = ""
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false

    @State private var notificationStatus = ""

    // Binds to just the LDAP handle; stores/reads the full email in AppStorage
    private var ldapHandle: Binding<String> {
        Binding(
            get: { username.components(separatedBy: "@").first ?? username },
            set: { newValue in
                let handle = newValue.components(separatedBy: "@").first ?? newValue
                username = handle.isEmpty ? "" : "\(handle)@mozilla.com"
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                notificationsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task { await checkNotificationStatus() }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)

                VStack(alignment: .leading) {
                    Text("LDAP Username")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("rcurran", text: ldapHandle)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onKeyPress(.tab) { .handled }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Profile")
        } footer: {
            Text("Enter just your LDAP handle, e.g. rcurran. Filters try pushes to your commits.")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            HStack {
                Label("Push Notifications", systemImage: "bell.fill")
                Spacer()
                Toggle("", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, newValue in
                        if newValue { Task { await requestNotifications() } }
                    }
            }

            if !notificationStatus.isEmpty {
                HStack {
                    Text("Status").foregroundStyle(.secondary)
                    Spacer()
                    Text(notificationStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get notified when your try pushes fail.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0").foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://treeherder.mozilla.org")!) {
                HStack {
                    Text("TreeHerder")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.caption)
                }
            }

            Link(destination: URL(string: "https://firefox-ci-tc.services.mozilla.com")!) {
                HStack {
                    Text("Taskcluster")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.caption)
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:    notificationStatus = "Enabled"
        case .denied:        notificationStatus = "Disabled in Settings"
        case .notDetermined: notificationStatus = "Not Set Up"
        default:             notificationStatus = "Unknown"
        }
    }

    private func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            notificationsEnabled = granted
            await checkNotificationStatus()
        } catch {
            notificationsEnabled = false
        }
    }
}
