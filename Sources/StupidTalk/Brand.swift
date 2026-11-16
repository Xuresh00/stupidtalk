import AppKit
import CoreText
import SwiftUI

// The Stupidesigner look: ink surfaces, cream text, amber accent, Mr. Oops.
// Colours and fonts match ThumbCheck. The wordmark and Mr. Oops are brand assets,
// see BRAND.md before reusing them.

/// Plain SwiftUI state. The alias keeps the property wrapper form working on every SDK.
typealias LocalState<Value> = SwiftUI.State<Value>

enum Brand {
    static let ink = Color(hex: 0x0B0B0B)
    static let surface = Color(hex: 0x161513)
    static let raised = Color(hex: 0x201E1B)
    static let line = Color(hex: 0x34302B)
    static let cream = Color(hex: 0xF5F1E9)
    static let muted = Color(hex: 0xB5AFA4)
    static let faint = Color(hex: 0x948E84)
    static let amber = Color(hex: 0xFDA501)
    static let amberBright = Color(hex: 0xFFB52E)
    static let red = Color(hex: 0xFF6B5E)
    static let green = Color(hex: 0x8FD694)

    static let inkNS = NSColor(srgbRed: 11.0 / 255, green: 11.0 / 255, blue: 11.0 / 255, alpha: 1)
    static let amberNS = NSColor(srgbRed: 253.0 / 255, green: 165.0 / 255, blue: 1.0 / 255, alpha: 1)
    static let redNS = NSColor(srgbRed: 255.0 / 255, green: 107.0 / 255, blue: 94.0 / 255, alpha: 1)

    /// Archivo Expanded Black, for the big titles.
    static func display(_ size: CGFloat) -> Font { Font.custom("Archivo-ExpandedBlack", size: size) }
    /// Archivo Expanded ExtraBold, for section titles.
    static func heading(_ size: CGFloat) -> Font { Font.custom("Archivo-ExpandedExtraBold", size: size) }
    static func text(_ size: CGFloat) -> Font { Font.custom("DMSans-Regular", size: size) }
    static func textMedium(_ size: CGFloat) -> Font { Font.custom("DMSans-Medium", size: size) }
    static func textBold(_ size: CGFloat) -> Font { Font.custom("DMSans-Bold", size: size) }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }
}

enum Assets {
    static let fontFiles = [
        "Archivo-ExpandedBlack", "Archivo-ExpandedExtraBold",
        "DMSans-Regular", "DMSans-Medium", "DMSans-SemiBold", "DMSans-Bold"
    ]

    /// Inside the built app the files sit in Contents/Resources. When run straight from
    /// `swift run` they come from the package's own resource bundle.
    static let root: URL = {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("oops-rock.png").path) {
            return resources
        }
        if let packaged = Bundle.module.resourceURL {
            return packaged.appendingPathComponent("Resources")
        }
        return Bundle.main.bundleURL
    }()

    static func registerFonts() {
        for name in fontFiles {
            let url = root.appendingPathComponent(name + ".ttf")
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: root.appendingPathComponent(name + ".png")) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The approved Mr. Oops poses, one per moment in the app.
enum OopsPose: String, Equatable {
    /// Default: the rock hand. Idle and welcome screens.
    case rock = "oops-rock"
    /// Pointing up. He is listening.
    case point = "oops-point"
    /// Pencil in hand. He is cleaning up your words.
    case pencil = "oops-pencil"
    /// At the laptop. He is typing.
    case laptop = "oops-laptop"
    /// The 100% sign. Done.
    case done = "oops-done"
    /// Question marks. He did not catch that.
    case confused = "oops-confused"
    /// Sunglasses. The about screen.
    case cool = "oops-cool"
}

struct OopsView: View {
    let pose: OopsPose

    var body: some View {
        if let image = Assets.image(pose.rawValue) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "cursorarrow")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Brand.amber)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.textBold(13))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? Brand.amberBright : Brand.amber, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.textMedium(13))
            .foregroundStyle(Brand.cream)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Brand.raised.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
    }
}

/// A rounded panel that groups related settings.
struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

/// One line in a card: a title, a short explanation, and a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    let control: Control

    init(_ title: String, detail: String = "", @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Brand.textMedium(14))
                    .foregroundStyle(Brand.cream)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Brand.text(12))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

struct Divide: View {
    var body: some View {
        Rectangle().fill(Brand.line).frame(height: 1)
    }
}
