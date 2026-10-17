#if os(iOS)
import CoreText
import SwiftUI

/// The bundled brand fonts: static instances of Bricolage Grotesque, Instrument Sans and
/// JetBrains Mono (cut by `ios/scripts/fonts.sh`, SIL OFL 1.1).
public enum QuickrFonts {
    /// PostScript names of the bundled files.
    public enum Face: String, CaseIterable, Sendable {
        case displaySemiBold = "BricolageGrotesque-SemiBold"
        case displayBold = "BricolageGrotesque-Bold"
        case sansRegular = "InstrumentSans-Regular"
        case sansMedium = "InstrumentSans-Medium"
        case sansSemiBold = "InstrumentSans-SemiBold"
        case monoRegular = "JetBrainsMono-Regular"
        case monoSemiBold = "JetBrainsMono-SemiBold"
    }

    /// Registers the fonts with CoreText for this process. Idempotent and cheap after the first
    /// call; `Font.qr` calls it, so apps and previews need not. Returns false if any face failed.
    @discardableResult
    public static func register() -> Bool { registered }

    private static let registered: Bool = {
        var ok = true
        for face in Face.allCases {
            guard let url = Bundle.module.url(forResource: face.rawValue, withExtension: "ttf") else {
                ok = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue { ok = false }
            }
        }
        return ok
    }()
}

/// The brand type ramp. Sizes follow the PWA; each style scales with Dynamic Type relative
/// to the text style it stands in for.
public enum QuickrTextStyle: CaseIterable, Sendable {
    /// Screen titles (Bricolage 28 bold).
    case largeTitle
    /// Tile and card titles (Bricolage 19 semibold).
    case title
    /// Section headers such as "Topics" (Bricolage 18 semibold).
    case section
    /// Question labels (Instrument 17 semibold).
    case label
    /// Running text (Instrument 16).
    case body
    /// Buttons and chips (Instrument 15 semibold).
    case callout
    /// Supporting text (Instrument 14).
    case subheadline
    /// Tile meta lines (Instrument 13).
    case footnote
    /// Badges and small labels (Instrument 12 semibold).
    case caption
    /// Numbers being entered (JetBrains Mono 20 semibold).
    case mono
    /// Small mono labels and counts (JetBrains Mono 12).
    case monoCaption

    var face: QuickrFonts.Face {
        switch self {
        case .largeTitle: .displayBold
        case .title, .section: .displaySemiBold
        case .label, .callout, .caption: .sansSemiBold
        case .body, .subheadline, .footnote: .sansRegular
        case .mono: .monoSemiBold
        case .monoCaption: .monoRegular
        }
    }

    var size: CGFloat {
        switch self {
        case .largeTitle: 28
        case .title: 19
        case .section: 18
        case .label: 17
        case .body: 16
        case .callout: 15
        case .subheadline: 14
        case .footnote: 13
        case .caption, .monoCaption: 12
        case .mono: 20
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title, .mono: .title3
        case .section, .label: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption, .monoCaption: .caption
        }
    }
}

extension Font {
    /// A brand font for one of the ramp's styles: `.font(.qr(.title))`.
    public static func qr(_ style: QuickrTextStyle) -> Font {
        qr(style.face, size: style.size, relativeTo: style.relativeTo)
    }

    /// A brand face at any size, still scaling with Dynamic Type.
    public static func qr(_ face: QuickrFonts.Face, size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        QuickrFonts.register()
        return .custom(face.rawValue, size: size, relativeTo: style)
    }
}
#endif
