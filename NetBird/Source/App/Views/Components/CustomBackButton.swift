//
//  CustomBackButton.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct CustomBackButton: View {
    var text : String
    var action: () -> Void
    
    var body: some View {
        Button(action: {
            action()
        }) {
            HStack {
                Image("chevron.left")
                Text(text)
                    .padding(.leading, 5)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(Color("TextPrimary"))
            }
        }
    }
}
