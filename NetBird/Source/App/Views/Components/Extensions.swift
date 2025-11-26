//
//  Extensions.swift
//  NetBird
//
//  Created by Diego Romar on 26/11/25.
//
import SwiftUI

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
