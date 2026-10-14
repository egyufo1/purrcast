// Renders docs/cover.png (README banner) in the app's webapp.wtf style.
// Run: swift Resources/Cover/render_cover.swift   (from the repository root)
import AppKit
import CoreText
import SwiftUI

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
for font in ["Geist-Variable.ttf", "GeistMono-Variable.ttf"] {
    CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Resources/Fonts/\(font)") as CFURL, .process, nil)
}
let mascot = NSImage(contentsOf: root.appendingPathComponent("Resources/Icon/purr_fire.svg"))!

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

let paper = Color(hex: 0xF5F0E7), cream = Color(hex: 0xFFFAF0), ink = Color(hex: 0x25221F), muted = Color(hex: 0x67605A)
let acid = Color(hex: 0xDFEF68), lavender = Color(hex: 0xBFABEF), lavenderLight = Color(hex: 0xEBE4F5), coral = Color(hex: 0xFF8059)

func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist", size: size).weight(weight) }
func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist Mono", size: size).weight(weight) }

extension View {
    func brutal(_ fill: Color, shadow: Color = ink, offset: CGFloat = 4, border: CGFloat = 2) -> some View {
        self.background(fill)
            .overlay(Rectangle().stroke(ink, lineWidth: border))
            .background(Rectangle().fill(shadow).offset(x: offset, y: offset))
    }

    func sticker(_ fill: Color = acid, angle: Double = -2) -> some View {
        self.font(mono(15, .medium)).textCase(.uppercase).tracking(0.8).foregroundStyle(ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .brutal(fill, offset: 3, border: 1.5)
            .rotationEffect(.degrees(angle))
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: 11.0, to: size.width, by: 22) {
                for y in stride(from: 11.0, to: size.height, by: 22) {
                    path.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                }
            }
            context.fill(path, with: .color(ink.opacity(0.1)))
        }
    }
}

struct CatCard: View {
    let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Image(nsImage: mascot).resizable().scaledToFit().frame(width: width * 0.84).offset(y: -width * 0.02)
            }
            .frame(width: width - 40, height: width * 0.86)
            .clipped()
            Rectangle().fill(ink).frame(height: 1.8).padding(.horizontal, 18)
            HStack {
                Text("CHIEF FORMAT INCINERATOR").font(mono(11)).tracking(0.7).foregroundStyle(ink)
                Spacer()
                Text("AirPlay ↗").sticker(acid, angle: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        .frame(width: width)
        .brutal(lavender, offset: 10)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 2) {
                Text("100% AIRPLAY").font(sans(21, .heavy)).tracking(-0.6)
                Text("0% MIRRORING").font(mono(10))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .brutal(coral, offset: 4)
            .rotationEffect(.degrees(8))
            .offset(x: 34, y: -24)
        }
        .rotationEffect(.degrees(2))
    }
}

/// A miniature of the player's control bar.
struct MiniControlBar: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("1:16:04").font(mono(12)).fixedSize()
                ZStack(alignment: .leading) {
                    Rectangle().fill(cream).frame(height: 10)
                    Rectangle().fill(lavender).frame(width: 300 * 0.7, height: 10)
                    Rectangle().stroke(ink, lineWidth: 1.5).frame(height: 10)
                    ForEach([0.12, 0.27, 0.41, 0.55, 0.69, 0.83], id: \.self) { x in
                        Rectangle().fill(ink).frame(width: 1.5, height: 10).offset(x: 300 * x)
                    }
                    Rectangle().fill(acid).frame(width: 12, height: 18)
                        .overlay(Rectangle().stroke(ink, lineWidth: 1.5))
                        .background(Rectangle().fill(ink).offset(x: 2, y: 2))
                        .offset(x: 300 * 0.7 - 6)
                }
                .frame(width: 300)
                Text("−32:35").font(mono(12)).fixedSize()
            }
            HStack(spacing: 14) {
                Image(systemName: "backward.end.fill")
                Image(systemName: "gobackward.10")
                Image(systemName: "pause.fill").font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(acid))
                    .overlay(Circle().stroke(ink, lineWidth: 2))
                    .background(Circle().fill(ink).offset(x: 3, y: 3))
                Image(systemName: "goforward.10")
                Image(systemName: "forward.end.fill")
                Text("14/21").font(mono(11, .semibold))
                Spacer()
                Image(systemName: "captions.bubble")
                Image(systemName: "list.bullet")
                Image(systemName: "airplayvideo")
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 440)
        .brutal(paper, offset: 5)
    }
}

struct Cover: View {
    var body: some View {
        ZStack {
            paper
            DotGrid()
            HStack(alignment: .center, spacing: 70) {
                VStack(alignment: .leading, spacing: 26) {
                    Text("MKV · HEVC · HDR · DTS → TV").sticker()
                    VStack(alignment: .leading, spacing: -10) {
                        Text("Purr")
                        Text("cast").padding(.horizontal, 10).background(lavender)
                    }
                    .font(sans(124, .heavy)).tracking(-8).foregroundStyle(ink)
                    Text("AirPlay any video from your Mac to your TV.\nNo mirroring. No “format not supported”.")
                        .font(sans(24, .medium)).foregroundStyle(ink).lineSpacing(4)
                    HStack(spacing: 14) {
                        Text("Seek anywhere").sticker(lavenderLight, angle: 1.5)
                        Text("All audio & subtitles").sticker(cream, angle: -1)
                        Text("76 languages").sticker(acid, angle: 2)
                    }
                }
                VStack(spacing: 46) {
                    CatCard()
                    MiniControlBar().rotationEffect(.degrees(-1.5))
                }
            }
            .padding(.horizontal, 80)
        }
        .frame(width: 1280, height: 720)
    }
}

try MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Cover())
    renderer.scale = 2
    let out = root.appendingPathComponent("docs/cover.png")
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("rendering failed")
    }
    try png.write(to: out)
    print("Kész: \(out.path)")
}
