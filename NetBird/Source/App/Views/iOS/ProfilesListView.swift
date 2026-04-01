//
//  ProfilesListView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct ProfilesListView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var profiles: [Profile] = []
    @State private var showAddSheet = false
    @State private var showSwitchAlert = false
    @State private var showRemoveAlert = false
    @State private var showLogoutAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var selectedProfile: Profile?

    private var activeProfile: Profile? {
        profiles.first(where: { $0.isActive })
    }

    private var inactiveProfiles: [Profile] {
        profiles.filter { !$0.isActive }
    }

    var body: some View {
        List {
            if let active = activeProfile {
                Section("Active") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(active.name)
                                .font(.body.bold())
                                .foregroundColor(Color("TextPrimary"))
                            if let url = ProfileManager.shared.managementURL(for: active.name) {
                                Text(url)
                                    .font(.footnote)
                                    .foregroundColor(Color("TextSecondary"))
                            }
                        }
                        Spacer()
                        Text("Active")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green)
                            .clipShape(Capsule())
                    }
                }
            }

            Section("All Profiles") {
                if inactiveProfiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.slash")
                            .font(.title2)
                            .foregroundColor(Color("TextSecondary"))
                        Text("No Additional Profiles")
                            .font(.subheadline.bold())
                            .foregroundColor(Color("TextPrimary"))
                        Text("Tap + to add a new profile")
                            .font(.footnote)
                            .foregroundColor(Color("TextSecondary"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(inactiveProfiles) { profile in
                        Button {
                            selectedProfile = profile
                            showSwitchAlert = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.body)
                                    .foregroundColor(Color("TextPrimary"))
                                if let url = ProfileManager.shared.managementURL(for: profile.name) {
                                    Text(url)
                                        .font(.footnote)
                                        .foregroundColor(Color("TextSecondary"))
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if profile.name != "default" {
                                Button(role: .destructive) {
                                    selectedProfile = profile
                                    showRemoveAlert = true
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }

                            Button {
                                selectedProfile = profile
                                showLogoutAlert = true
                            } label: {
                                Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .tint(.gray)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .onAppear {
            loadProfiles()
        }
        .sheet(isPresented: $showAddSheet) {
            AddProfileSheet {
                loadProfiles()
            }
        }
        .alert("Switch Profile", isPresented: $showSwitchAlert, presenting: selectedProfile) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Switch", role: .destructive) {
                switchToProfile(profile)
            }
        } message: { profile in
            Text("VPN will be disconnected to switch to \u{00AB}\(profile.name)\u{00BB}. Continue?")
        }
        .alert("Remove Profile", isPresented: $showRemoveAlert, presenting: selectedProfile) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeProfile(profile)
            }
        } message: { profile in
            Text("Profile \u{00AB}\(profile.name)\u{00BB} and all its data will be deleted. This action cannot be undone.")
        }
        .alert("Logout from Profile", isPresented: $showLogoutAlert, presenting: selectedProfile) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Logout", role: .destructive) {
                logoutProfile(profile)
            }
        } message: { profile in
            Text("You will need to re-authenticate to use profile \u{00AB}\(profile.name)\u{00BB} again.")
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Actions

    private func loadProfiles() {
        profiles = ProfileManager.shared.listProfiles()
    }

    private func switchToProfile(_ profile: Profile) {
        viewModel.performClose()
        viewModel.switchConnectionInfo(to: profile.name)

        do {
            try ProfileManager.shared.switchProfile(profile.name)
            viewModel.reloadConfiguration()
            viewModel.activeProfileName = ProfileManager.shared.getActiveProfileName()
            if let url = ProfileManager.shared.managementURL(for: profile.name) {
                Preferences.saveManagementURL(url)
            }
            loadProfiles()
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func removeProfile(_ profile: Profile) {
        do {
            try ProfileManager.shared.removeProfile(profile.name)
            loadProfiles()
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func logoutProfile(_ profile: Profile) {
        if profile.isActive {
            viewModel.performClose()
        }
        do {
            try ProfileManager.shared.logoutProfile(profile.name)
            loadProfiles()
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
}

#Preview {
    NavigationView {
        ProfilesListView()
            .environmentObject(ViewModel())
    }
}

#endif
