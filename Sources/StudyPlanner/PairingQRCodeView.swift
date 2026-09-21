import SwiftUI
import AppKit
import CoreImage

struct PairingQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = Self.makeImage(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("二维码生成失败", systemImage: "qrcode")
            }
        }
        .frame(width: 220, height: 220)
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Android 配对二维码")
    }

    private static func makeImage(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
