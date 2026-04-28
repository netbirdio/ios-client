//
//  ProfileBadge.swift
//  NetBird
//

import SwiftUI

#if os(iOS)

struct ProfileBadge: View {
    let profileName: String
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                Text(profileName)
                    .font(.caption.bold())
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(Capsule())
        }
    }
}

#Preview {
    ProfileBadge(profileName: "work")
}

#endif
