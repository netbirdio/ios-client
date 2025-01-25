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
    func darker(by percentage: CGFloat = 0.1) -> Color {
        let adjustmentFactor = max(0, min(1, percentage))
        
        guard let uiColor = UIColor(self).cgColor.components, uiColor.count >= 3 else {
            return self
        }
        
        let red = max(0, uiColor[0] - adjustmentFactor)
        let green = max(0, uiColor[1] - adjustmentFactor)
        let blue = max(0, uiColor[2] - adjustmentFactor)
        
        return Color(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

struct SolidButton_Previews: PreviewProvider {
    static var previews: some View {
        SolidButton(text: "save") {
            print("noop")
        }
    }
}
