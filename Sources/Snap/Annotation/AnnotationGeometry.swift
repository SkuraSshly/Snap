import AppKit

/// 标注的几何计算：外框、点中判断、平移。坐标都是画布坐标（见 Annotation）。
@MainActor
extension Annotation {
    /// 包含整个标注（含线宽、箭头头部、文字）的外框，用来画选中框和限制移动范围
    var bounds: CGRect {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .mosaic(let rect), .blur(let rect):
            return rect
        case .arrow(let a, let b):
            let head = max(12, lineWidth * 4) * 0.45
            return Self.box(a, b).insetBy(dx: -head, dy: -head)
        case .line(let a, let b):
            return Self.box(a, b).insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .pen(let points):
            return Self.box(points).insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .highlighter(let points):
            return Self.box(points).insetBy(dx: -highlighterWidth / 2, dy: -highlighterWidth / 2)
        case .text(let string, let topLeft):
            let size = AnnotationRenderer.textSize(NSAttributedString(
                string: string, attributes: Self.textAttributes(color: color, fontSize: fontSize)))
            return CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        case .counter(_, let center):
            return CGRect(x: center.x - counterRadius, y: center.y - counterRadius, width: counterRadius * 2, height: counterRadius * 2)
        }
    }

    /// 鼠标是否正好在这个标注画出来的地方：用和绘制时相同的路径、相同的线宽判断，
    /// 只额外放宽 1 点（抗锯齿的边缘）。空心的方框、椭圆只认线条本身，里面不算。
    func contains(_ point: CGPoint) -> Bool {
        let margin: CGFloat = 1
        func onStroke(_ path: CGPath, width: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) -> Bool {
            path.copy(strokingWithWidth: width + margin * 2, lineCap: cap, lineJoin: join, miterLimit: 10).contains(point)
        }
        switch shape {
        case .rectangle(let rect):
            return onStroke(CGPath(rect: rect, transform: nil), width: lineWidth, join: .miter)
        case .ellipse(let rect):
            return onStroke(CGPath(ellipseIn: rect, transform: nil), width: lineWidth)
        case .mosaic(let rect), .blur(let rect):
            return rect.contains(point)
        case .line(let a, let b):
            return onStroke(Self.segment(a, b), width: lineWidth)
        case .arrow(let a, let b):
            return Self.arrowPath(from: a, to: b, width: lineWidth).contains(point)
                || onStroke(Self.segment(a, b), width: lineWidth)
        case .pen(let points):
            return onStroke(AnnotationRenderer.smoothPath(points), width: lineWidth)
        case .highlighter(let points):
            return onStroke(AnnotationRenderer.smoothPath(points), width: highlighterWidth, cap: .square)
        case .text:
            return bounds.contains(point)
        case .counter(_, let center):
            return hypot(point.x - center.x, point.y - center.y) <= counterRadius + margin
        }
    }

    private static func segment(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    /// 箭头头部的三角形（与 AnnotationRenderer 的画法一致），稍微放大 1 点
    private static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return path }
        let ux = dx / length, uy = dy / length
        let headLength = min(max(12, width * 4), length * 0.5)
        let half = headLength * 0.45
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        path.move(to: to)
        path.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        path.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        path.closeSubpath()
        return path.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10).union(path)
    }

    /// 平移后的标注（id 不变）
    func moved(by d: CGVector) -> Annotation {
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + d.dx, y: point.y + d.dy) }
        func r(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: d.dx, dy: d.dy) }
        var copy = self
        copy.shape = switch shape {
        case .rectangle(let rect): .rectangle(r(rect))
        case .ellipse(let rect): .ellipse(r(rect))
        case .mosaic(let rect): .mosaic(r(rect))
        case .blur(let rect): .blur(r(rect))
        case .arrow(let a, let b): .arrow(from: p(a), to: p(b))
        case .line(let a, let b): .line(from: p(a), to: p(b))
        case .pen(let points): .pen(points.map(p))
        case .highlighter(let points): .highlighter(points.map(p))
        case .text(let string, let topLeft): .text(string, topLeft: p(topLeft))
        case .counter(let number, let center): .counter(number, center: p(center))
        }
        return copy
    }

    // MARK: - 调整大小

    /// 选中后能拖的控制点：方框类（矩形、椭圆、马赛克、模糊）是外框的 8 个点，直线和箭头是两个端点；
    /// 画笔、荧光笔、文字、序号没有控制点，只能移动
    enum ResizeHandle: Equatable {
        case frame(RegionSelector.Handle)
        case start, end
    }

    /// 方框类标注的框（就是画的时候拖出来的那个矩形，不含线宽）
    var resizableFrame: CGRect? {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect), .blur(let rect): rect
        default: nil
        }
    }

    /// 所有控制点和它们的位置
    var resizeHandles: [(handle: ResizeHandle, point: CGPoint)] {
        switch shape {
        case .arrow(let a, let b), .line(let a, let b):
            return [(.start, a), (.end, b)]
        default:
            guard let frame = resizableFrame else { return [] }
            return RegionSelector.Handle.allCases.map { (.frame($0), $0.point(in: frame)) }
        }
    }

    /// 把某个控制点拖到 p 之后的标注（id 不变）。总是从拖动开始时的样子计算，越过对边时自动翻转。
    /// keepRatio（按住 Shift）：方框拖角时保持原来的宽高比，端点沿 45° 的整数倍方向
    func resized(_ handle: ResizeHandle, to p: CGPoint, keepRatio: Bool) -> Annotation {
        var copy = self
        switch (shape, handle) {
        case (.arrow(_, let b), .start): copy.shape = .arrow(from: Self.snapped(p, around: b, keepRatio), to: b)
        case (.arrow(let a, _), .end): copy.shape = .arrow(from: a, to: Self.snapped(p, around: a, keepRatio))
        case (.line(_, let b), .start): copy.shape = .line(from: Self.snapped(p, around: b, keepRatio), to: b)
        case (.line(let a, _), .end): copy.shape = .line(from: a, to: Self.snapped(p, around: a, keepRatio))
        case (_, .frame(let h)):
            guard let frame = resizableFrame else { return self }
            let rect = Self.resized(frame, handle: h, to: p, keepRatio: keepRatio)
            copy.shape = switch shape {
            case .ellipse: .ellipse(rect)
            case .mosaic: .mosaic(rect)
            case .blur: .blur(rect)
            default: .rectangle(rect)
            }
        default:
            break
        }
        return copy
    }

    private static func resized(_ rect: CGRect, handle: RegionSelector.Handle, to p: CGPoint, keepRatio: Bool) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topRight: maxX = p.x; maxY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomLeft: minX = p.x; minY = p.y
        case .left: minX = p.x
        }
        // 拖角时的锚点：对面那个角
        let anchor: CGPoint? = switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight: CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        default: nil
        }
        if keepRatio, let anchor, rect.width > 0, rect.height > 0 {
            // 按拖得多的那个方向等比缩放
            let w = p.x - anchor.x, h = p.y - anchor.y
            let ratio = rect.width / rect.height
            let width = max(abs(w), abs(h) * ratio), height = width / ratio
            let end = CGPoint(x: anchor.x + (w < 0 ? -width : width), y: anchor.y + (h < 0 ? -height : height))
            return box(anchor, end)
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// 端点：按住 Shift 时沿 45° 的整数倍方向（相对另一端）
    private static func snapped(_ p: CGPoint, around other: CGPoint, _ snap: Bool) -> CGPoint {
        guard snap else { return p }
        let dx = p.x - other.x, dy = p.y - other.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: other.x + cos(angle) * length, y: other.y + sin(angle) * length)
    }

    // MARK: - 辅助

    private static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func box(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}
