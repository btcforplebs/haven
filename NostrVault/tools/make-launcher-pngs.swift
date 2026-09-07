// Regenerates the legacy launcher PNGs from the Mac/iOS app icon art.
//
//   swift NostrVault/tools/make-launcher-pngs.swift
//
// Adaptive icons (mipmap-anydpi-v26 + the three vector layers) are what every
// device this app supports actually draws — minSdk is 26. These PNGs exist for
// launchers that ask for the legacy drawable anyway, and for the Play/Zapstore
// listing to have something at 512. Source of truth for the art stays
// HavenApp/Resources/AppIcon-source.svg via its rendered 1024 PNG; never
// hand-edit the PNGs below.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tools
    .deletingLastPathComponent()   // NostrVault
    .deletingLastPathComponent()   // repo root
let source = repo.appendingPathComponent(
    "HavenApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png")
let res = repo.appendingPathComponent("NostrVault/app/src/main/res")

guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("cannot read \(source.path)")
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("finalize failed \(url.path)") }
}

func render(size: Int, round: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    if round { ctx.addEllipse(in: rect); ctx.clip() }
    ctx.interpolationQuality = .high
    ctx.draw(art, in: rect)
    return ctx.makeImage()!
}

// mdpi 48, hdpi 72, xhdpi 96, xxhdpi 144, xxxhdpi 192 — the sizes already in res/.
for (bucket, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    let dir = res.appendingPathComponent("mipmap-\(bucket)")
    write(render(size: size, round: false), to: dir.appendingPathComponent("ic_launcher.png"))
    write(render(size: size, round: true), to: dir.appendingPathComponent("ic_launcher_round.png"))
    print("mipmap-\(bucket): \(size)px square + round")
}
