//
//  TVQRCodeSheet.swift
//  NetBird
//
//  Reusable QR code sheet for tvOS.
//  Displays a scannable QR code so users can open URLs on their phone.
//

import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

#if os(tvOS)

/// Full-screen sheet showing a QR code so users can scan with their phone.
struct TVQRCodeSheet: View {
    let url: String
    let title: String
    let subtitle: String

    @State private var qrImage: UIImage?

    var body: some View {
        ZStack {
            TVGradientBackground()

            VStack(spacing: 50) {
                Text(title)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(TVColors.textPrimary)

                // QR code on white background
                if let qrImage {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white)
                        .frame(width: 380, height: 380)
                        .overlay(
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(32)
                        )
                }

                VStack(spacing: 16) {
                    Text(subtitle)
                        .font(.system(size: 32))
                        .foregroundColor(TVColors.textSecondary)

                    Text(url)
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                        .foregroundColor(TVColors.textSecondary.opacity(0.7))
                }
            }
            .padding(80)
        }
        .onAppear {
            qrImage = generateQRCode(from: url)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#endif
