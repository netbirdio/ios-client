//
//  ExitNodeSummaryRow.swift
//  NetBird
//

import SwiftUI

struct ExitNodeSummaryRow: View {
    @ObservedObject var routeViewModel: RoutesViewModel

    var body: some View {
        NavigationLink(destination: ExitNodeSelectionView(routeViewModel: routeViewModel)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exit Node")
                        .foregroundColor(Color("TextPeerCard"))
                    Text(routeViewModel.selectedExitNode?.name ?? "Not Selected")
                        .font(.footnote)
                        .foregroundColor(Color("TextSecondary"))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(Color("TextSecondary"))
            }
            .padding()
            .background(Color("BgPeerCard"))
            .cornerRadius(8)
        }
        .padding([.leading, .trailing])
        .padding(.bottom, 8)
    }
}
