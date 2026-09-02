//
//  ProfilesListView.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

/// Per-profile display values shown under a profile's name. Resolved when the
/// list is loaded rather than while a row renders — see `loadProfiles()`.
private struct ProfileDisplayDetails {
    let serverURL: String?
    let account: String?
}

struct ProfilesListView: View {
    @EnvironmentObject var viewModel: ViewModel
    @State private var profiles: [Profile] = []
    @State private var profileDetails: [String: ProfileDisplayDetails] = [:]
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

    /// The Go profile manager rejects switch/add/rename/remove under this
    /// gate, so the UI mirrors it: the entries that would fail are removed
    /// rather than left to error out. Logout is not gated and stays.
    private var profilesManaged: Bool {
        viewModel.mdmRestrictions.features.disableProfiles
    }

    var body: some View {
        List {
            activeSection
            managedNoticeSection
            allProfilesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                addProfileButton
            }
        }
        .onAppear {
            viewModel.refreshMDMRestrictions()
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

    /// Kept out of the toolbar builder: a conditional inside
    /// ToolbarContentBuilder is markedly more expensive to type-check than
    /// the same conditional in a plain ViewBuilder.
    @ViewBuilder
    private var addProfileButton: some View {
        if !profilesManaged {
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Sections
    //
    // Split out of `body` deliberately: as one expression the List exceeded
    // what the SwiftUI type-checker will resolve in reasonable time.

    @ViewBuilder
    private var activeSection: some View {
        if let active = activeProfile {
            Section("Active") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(active.name)
                            .font(.body.bold())
                            .foregroundColor(Color("TextPrimary"))
                        profileSubtitle(for: active)
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
    }

    @ViewBuilder
    private var managedNoticeSection: some View {
        if profilesManaged {
            Section {
                MDMManagedFooter()
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var allProfilesSection: some View {
        Section("All Profiles") {
            if inactiveProfiles.isEmpty {
                emptyProfilesPlaceholder
            } else {
                ForEach(inactiveProfiles) { profile in
                    inactiveProfileRow(profile)
                }
            }
        }
    }

    private var emptyProfilesPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.title2)
                .foregroundColor(Color("TextSecondary"))
            Text("No Additional Profiles")
                .font(.subheadline.bold())
                .foregroundColor(Color("TextPrimary"))
            Text(profilesManaged ? "Profile management is disabled" : "Tap + to add a new profile")
                .font(.footnote)
                .foregroundColor(Color("TextSecondary"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func inactiveProfileRow(_ profile: Profile) -> some View {
        Button {
            guard !profilesManaged else { return }
            selectedProfile = profile
            showSwitchAlert = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.body)
                    .foregroundColor(Color("TextPrimary"))
                profileSubtitle(for: profile)
            }
        }
        .mdmLocked(profilesManaged)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !profile.isDefault && !profilesManaged {
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

    // MARK: - Rows

    /// Server and account lines under a profile's name. The account is the one the
    /// profile last signed in with — it is also what goes out as the login_hint on
    /// the next login, so showing it makes visible which account a re-login returns
    /// to. A profile that never completed an SSO login, or was logged out, has none.
    ///
    /// Reads only what `loadProfiles()` already resolved: both lookups touch the
    /// filesystem, and a body may be evaluated any number of times.
    @ViewBuilder
    private func profileSubtitle(for profile: Profile) -> some View {
        let details = profileDetails[profile.id]
        if let url = details?.serverURL {
            Text(url)
                .font(.footnote)
                .foregroundColor(Color("TextSecondary"))
        }
        if let email = details?.account {
            Text(email)
                .font(.footnote)
                .foregroundColor(Color("TextSecondary"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func loadProfiles() {
        let loaded = ProfileManager.shared.listProfiles()
        // Resolved here, not while a row renders: managementURL(forID:) reads the
        // profile's config and writes the resolved URL back to the connection
        // cache, so calling it inside `body` turns every redraw into file I/O.
        // The account comes free with the listing — the Go core returns it on the
        // profile itself, so it costs no extra lookup.
        profileDetails = Dictionary(uniqueKeysWithValues: loaded.map { profile in
            (profile.id, ProfileDisplayDetails(
                serverURL: ProfileManager.shared.managementURL(forID: profile.id),
                account: profile.email.isEmpty ? nil : profile.email
            ))
        })
        profiles = loaded
    }

    private func switchToProfile(_ profile: Profile) {
        viewModel.performClose()

        do {
            try ProfileManager.shared.switchProfile(id: profile.id)
            viewModel.switchConnectionInfo(toID: profile.id)
            viewModel.reloadConfiguration()
            viewModel.activeProfileName = ProfileManager.shared.getActiveProfileName()
            if let url = ProfileManager.shared.managementURL(forID: profile.id) {
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
            try ProfileManager.shared.removeProfile(id: profile.id)
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
            try ProfileManager.shared.logoutProfile(id: profile.id)
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
