//
//  MDMManagedNotice.swift
//  NetBird
//
//  Shared presentation for controls an MDM policy has taken over.
//
//  Convention across the app:
//    - a managed *setting* stays visible and is locked, so the user can see
//      the enforced value and understand why it will not budge;
//    - a gated *feature* (features.* in the restrictions snapshot) is hidden
//      outright, because there is nothing meaningful to show.
//  A control that silently vanishes reads as a bug; one that is visibly
//  locked explains itself.
//

import SwiftUI

/// Footer line marking a locked control. The wording matches the desktop
/// client so a user who runs both gets the same explanation.
struct MDMManagedFooter: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
            Text("Managed by your organization")
        }
        .foregroundColor(Color("TextSecondary"))
    }
}

/// Trailing badge for a locked row inside a list.
struct MDMManagedBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundColor(Color("TextSecondary"))
            .accessibilityLabel("Managed by your organization")
    }
}

extension View {
    /// Locks a control the policy manages: still readable, no longer editable.
    @ViewBuilder
    func mdmLocked(_ locked: Bool) -> some View {
        if locked {
            self.disabled(true)
                .opacity(0.55)
        } else {
            self
        }
    }
}
