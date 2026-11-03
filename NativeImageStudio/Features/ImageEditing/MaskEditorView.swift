import SwiftUI

/// Paint the area to regenerate over the source photo.
public struct MaskEditorView: View {
    let imageURL: URL
    let imageAspect: CGFloat
    @Binding var strokes: [MaskStroke]
    @State private var brush: CGFloat = 0.06
    @State private var erasing = false
    @State private var current: MaskStroke?

    public init(imageURL: URL, imageAspect: CGFloat, strokes: Binding<[MaskStroke]>) {
        self.imageURL = imageURL
        self.imageAspect = imageAspect
        self._strokes = strokes
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $erasing) {
                    Label("Maluj", systemImage: "paintbrush.pointed").tag(false)
                    Label("Gumka", systemImage: "eraser").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 200)
                Slider(value: $brush, in: 0.01...0.25) { Text("Pędzel") }.frame(maxWidth: 200)
                Button("Cofnij") { _ = strokes.popLast() }.disabled(strokes.isEmpty)
                Button("Wyczyść") { strokes.removeAll() }.disabled(strokes.isEmpty)
                Spacer()
            }
            GeometryReader { geo in
                let rect = FitGeometry.fittedRect(aspect: imageAspect, in: geo.size)
                ZStack(alignment: .topLeading) {
                    ThumbnailView(url: imageURL, maxPixel: 1600, contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                    Canvas { ctx, _ in
                        for s in strokes + (current.map { [$0] } ?? []) {
                            draw(s, in: rect, ctx: ctx)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let p = CGPoint(x: (v.location.x - rect.minX) / rect.width, y: (v.location.y - rect.minY) / rect.height)
                        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                        if current == nil { current = MaskStroke(points: [], width: brush, erase: erasing) }
                        current?.points.append(p)
                    }
                    .onEnded { _ in
                        if let c = current { strokes.append(c) }
                        current = nil
                    })
            }
            Text("Zamaluj obszar do wygenerowania na nowo (czerwony). Reszta zdjęcia zostanie zachowana.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func draw(_ s: MaskStroke, in rect: CGRect, ctx: GraphicsContext) {
        guard !s.points.isEmpty else { return }
        var path = Path()
        let pts = s.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        path.addLines(pts.count == 1 ? [pts[0], pts[0]] : pts)
        let w = s.width * min(rect.width, rect.height)
        let color: Color = s.erase ? .black.opacity(0.55) : .red.opacity(0.5)
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
}
