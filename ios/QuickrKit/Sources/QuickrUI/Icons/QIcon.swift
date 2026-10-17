#if os(iOS)
import SwiftUI

/// The PWA's 30 stroke icons (`frontend/src/components/ui/Icon.tsx`). Most map to an SF Symbol;
/// the rest are ported as paths on the PWA's 24-unit grid.
///
/// `QIcon.plus.view(size: 20)` draws one; `systemName` feeds `Label` and toolbar APIs.
public enum QIcon: String, CaseIterable, Sendable {
    case plus, x, check, search, chevronLeft, chevronRight, chevronDown, up, down, trash, edit
    case archive, restore, record, list, chart, layers, download, settings, home, dots, eye
    case alert, info, clock, grip, cloudOff, sync, bell, share, plusSquare, phone

    /// The SF Symbol it maps to, or nil when it is drawn as a path.
    public var systemName: String? {
        switch self {
        case .plus: "plus"
        case .x: "xmark"
        case .check: "checkmark"
        case .search: "magnifyingglass"
        case .chevronLeft: "chevron.left"
        case .chevronRight: "chevron.right"
        case .chevronDown, .down: "chevron.down"
        case .up: "chevron.up"
        case .trash: "trash"
        case .edit: "pencil"
        case .archive: "archivebox"
        case .restore: "arrow.counterclockwise"
        case .record: "record.circle"
        case .list: "list.bullet"
        case .chart: "chart.bar.xaxis"
        case .layers: "square.3.layers.3d"
        case .download: "arrow.down.to.line"
        case .settings: "gearshape"
        case .home: "house"
        case .dots: "ellipsis"
        case .eye: "eye"
        case .alert: "exclamationmark.triangle"
        case .info: "info.circle"
        case .clock: "clock"
        case .cloudOff: "icloud.slash"
        case .sync: "arrow.triangle.2.circlepath"
        case .bell: "bell"
        case .share: "square.and.arrow.up"
        case .plusSquare: "plus.square"
        case .phone: "iphone"
        case .grip: nil
        }
    }

    /// The icon at `size` points, in the current foreground style. `weight` thickens the stroke
    /// (the PWA uses 2 by default and up to 3 for small glyphs on filled circles).
    @MainActor
    public func view(size: CGFloat = 20, weight: Font.Weight = .semibold) -> some View {
        QIconView(self, size: size, weight: weight)
    }
}

/// Draws a ``QIcon``. Decorative by default: label the control that contains it.
public struct QIconView: View {
    let icon: QIcon
    let size: CGFloat
    let weight: Font.Weight

    public init(_ icon: QIcon, size: CGFloat = 20, weight: Font.Weight = .semibold) {
        self.icon = icon
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        Group {
            if let name = icon.systemName {
                // SF Symbols draw at about 0.8 of the point size; the PWA's glyphs fill ~0.75 of
                // their 24-unit box, so a font of 0.8 × size lines the two up.
                Image(systemName: name)
                    .font(.system(size: size * 0.8, weight: weight))
            } else {
                GripShape()
                    .fill(.foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The PWA's drag handle: two columns of three dots (24-unit grid, 3.2 stroke round caps).
struct GripShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let radius = 1.6 * unit
        var path = Path()
        for x in [9.0, 15.0] {
            for y in [6.0, 12.0, 18.0] {
                let c = CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
                path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return path
    }
}

/// The quickR mark from `frontend/public/favicon.svg`: a "q" with speed lines. Draw it on an
/// accent rounded square for the header logo.
public struct QuickrMark: View {
    let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        // The SVG maps (x, y) to 256 + 0.9 × (x − 218, y − 268) on a 512 box.
        let s = size / 512
        let map = { (x: CGFloat, y: CGFloat) in CGPoint(x: (256 + 0.9 * (x - 218)) * s, y: (256 + 0.9 * (y - 268)) * s)
        }
        Canvas { ctx, _ in
            let bowl = Path(
                ellipseIn: CGRect(origin: map(174, 154), size: CGSize(width: 176 * 0.9 * s, height: 176 * 0.9 * s)))
            let thick = StrokeStyle(lineWidth: 56 * 0.9 * s, lineCap: .round)
            ctx.stroke(bowl, with: .color(.white), style: thick)
            var stem = Path()
            stem.move(to: map(350, 186))
            stem.addLine(to: map(350, 382))
            ctx.stroke(stem, with: .color(.white), style: thick)
            var lines = Path()
            for (x0, x1, y) in [(88.0, 132.0, 202.0), (70, 132, 242), (88, 132, 282)] {
                lines.move(to: map(x0, y))
                lines.addLine(to: map(x1, y))
            }
            ctx.stroke(
                lines, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 24 * 0.9 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
        .background(Color.qr.accent, in: RoundedRectangle(cornerRadius: size * 116 / 512, style: .continuous))
        .accessibilityHidden(true)
    }
}

#Preview("Icons") {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 16) {
        ForEach(QIcon.allCases, id: \.self) { icon in
            VStack(spacing: 4) {
                icon.view(size: 24)
                Text(icon.rawValue).font(.qr(.monoCaption)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
    .foregroundStyle(.qr.ink)
    .padding()
    .background(Color.qr.paper)
}
#endif
