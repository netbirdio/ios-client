//
//  TabButtonStyle.swift
//  NetBird
//
//  Created by Pascal Fischer on 06.05.24.
//

import SwiftUI

struct TabBarButton: View {
    let label: String
    let image: String
    @Binding var selectedTab: Int
    let index: Int

    var body: some View {
        Button(action: {
            withAnimation { selectedTab = index }
        }) {
            VStack {
                Image(image)
                Text(label)
            }
            .foregroundColor(selectedTab == index ? .accentColor : .gray)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .buttonStyle(PlainButtonStyle()) 
        .frame(maxWidth: .infinity)
    }
}
