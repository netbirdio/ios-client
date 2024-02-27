//
//  SolidButton.swift
//  NetBirdiOS
//
//  Created by Pascal Fischer on 01.08.23.
//

import SwiftUI

struct SolidButton: View {
    var text : String
    var action: () -> Void
    var body: some View {
        Button {
            action()
        } label: {
            Text(text)
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity) 
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.orange.darker(), lineWidth: 2)
                        )
                )
        }
    }
}

extension Color {
    func darker() -> Color {
        let components = UIColor(self).cgColor.components!
        return Color(red: Double(components[0] * 0.9),
                     green: Double(components[1] * 0.9),
                     blue: Double(components[2] * 0.9))
    }
}

struct SolidButton_Previews: PreviewProvider {
    static var previews: some View {
        SolidButton(text: "save") {
            print("noop")
        }
    }
}
