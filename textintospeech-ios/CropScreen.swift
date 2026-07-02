import SwiftUI
import UIKit

/// Full-screen step shown right after the user picks a picture or snaps a photo: they drag a box
/// around just the words they want, and only that part is sent to OCR. This keeps
/// screenshots/photos from pulling in clocks, buttons, captions and other clutter.
struct CropScreen: View {
    let image: UIImage
    let onCancel: () -> Void
    let onCropped: (UIImage) -> Void

    /// Which part of the crop box a drag is moving.
    private enum Handle { case topLeft, topRight, bottomLeft, bottomRight, move, none }

    @State private var crop: CGRect?
    @State private var imageRect: CGRect = .zero
    @State private var activeHandle: Handle = .none
    @State private var lastDragPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            let rect = fitRect(container: container, width: image.size.width, height: image.size.height)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Canvas { context, _ in
                    if let crop { drawOverlay(context: context, crop: crop, container: container) }
                }
                .allowsHitTesting(false)

                controls
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onAppear { seed(rect) }
            .onChange(of: rect) { _, newRect in seed(newRect) }
        }
        .statusBarHidden()
    }

    private func seed(_ rect: CGRect) {
        imageRect = rect
        guard rect.width > 0, rect.height > 0 else { return }
        let insetX = rect.width * 0.08
        let insetY = rect.height * 0.10
        crop = rect.insetBy(dx: insetX, dy: insetY)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if lastDragPoint == nil {
                    activeHandle = hitTest(point: value.startLocation)
                    lastDragPoint = value.startLocation
                }
                guard let last = lastDragPoint, let current = crop else { return }
                let delta = CGPoint(x: value.location.x - last.x, y: value.location.y - last.y)
                lastDragPoint = value.location
                crop = applyDrag(handle: activeHandle, crop: current, delta: delta, bounds: imageRect)
            }
            .onEnded { _ in
                activeHandle = .none
                lastDragPoint = nil
            }
    }

    private var controls: some View {
        VStack {
            Text("Drag the corners around the text you want")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
                .padding(16)
            Spacer()
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.white)
                        .overlay(RoundedCornerBorder())
                }
                Button {
                    if let crop { onCropped(cropImage(selection: crop)) }
                } label: {
                    Label("Read this", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(.black)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                }
            }
            .padding(16)
        }
    }

    private struct RoundedCornerBorder: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 16).stroke(.white, lineWidth: 1.5)
        }
    }

    // MARK: - Geometry (a direct port of the Android crop math)

    /// Picks the handle nearest the touch point, or `.move` when inside the box.
    private func hitTest(point: CGPoint) -> Handle {
        guard let crop else { return .none }
        let radius: CGFloat = 40
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: crop.minX, y: crop.minY)),
            (.topRight, CGPoint(x: crop.maxX, y: crop.minY)),
            (.bottomLeft, CGPoint(x: crop.minX, y: crop.maxY)),
            (.bottomRight, CGPoint(x: crop.maxX, y: crop.maxY)),
        ]
        if let nearest = corners.min(by: { distance($0.1, point) < distance($1.1, point) }),
           distance(nearest.1, point) <= radius {
            return nearest.0
        }
        return crop.contains(point) ? .move : .none
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Applies a drag `delta` to `crop` for the given `handle`, clamped inside `bounds`.
    private func applyDrag(handle: Handle, crop: CGRect, delta: CGPoint, bounds: CGRect) -> CGRect {
        let minSize: CGFloat = 64
        switch handle {
        case .move:
            let dx = min(max(delta.x, bounds.minX - crop.minX), bounds.maxX - crop.maxX)
            let dy = min(max(delta.y, bounds.minY - crop.minY), bounds.maxY - crop.maxY)
            return crop.offsetBy(dx: dx, dy: dy)
        case .topLeft:
            let x = min(max(crop.minX + delta.x, bounds.minX), crop.maxX - minSize)
            let y = min(max(crop.minY + delta.y, bounds.minY), crop.maxY - minSize)
            return CGRect(x: x, y: y, width: crop.maxX - x, height: crop.maxY - y)
        case .topRight:
            let r = min(max(crop.maxX + delta.x, crop.minX + minSize), bounds.maxX)
            let y = min(max(crop.minY + delta.y, bounds.minY), crop.maxY - minSize)
            return CGRect(x: crop.minX, y: y, width: r - crop.minX, height: crop.maxY - y)
        case .bottomLeft:
            let x = min(max(crop.minX + delta.x, bounds.minX), crop.maxX - minSize)
            let b = min(max(crop.maxY + delta.y, crop.minY + minSize), bounds.maxY)
            return CGRect(x: x, y: crop.minY, width: crop.maxX - x, height: b - crop.minY)
        case .bottomRight:
            let r = min(max(crop.maxX + delta.x, crop.minX + minSize), bounds.maxX)
            let b = min(max(crop.maxY + delta.y, crop.minY + minSize), bounds.maxY)
            return CGRect(x: crop.minX, y: crop.minY, width: r - crop.minX, height: b - crop.minY)
        case .none:
            return crop
        }
    }

    /// Dims everything outside the selection, outlines it, and draws grab handles + thirds guides.
    private func drawOverlay(context: GraphicsContext, crop r: CGRect, container: CGSize) {
        let dim = Color.black.opacity(0.55)
        context.fill(Path(CGRect(x: 0, y: 0, width: container.width, height: r.minY)), with: .color(dim))
        context.fill(Path(CGRect(x: 0, y: r.maxY, width: container.width, height: container.height - r.maxY)), with: .color(dim))
        context.fill(Path(CGRect(x: 0, y: r.minY, width: r.minX, height: r.height)), with: .color(dim))
        context.fill(Path(CGRect(x: r.maxX, y: r.minY, width: container.width - r.maxX, height: r.height)), with: .color(dim))

        // Rule-of-thirds guides for easier alignment.
        let guide = Color.white.opacity(0.35)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            var v = Path(); v.move(to: CGPoint(x: x, y: r.minY)); v.addLine(to: CGPoint(x: x, y: r.maxY))
            var h = Path(); h.move(to: CGPoint(x: r.minX, y: y)); h.addLine(to: CGPoint(x: r.maxX, y: y))
            context.stroke(v, with: .color(guide), lineWidth: 1)
            context.stroke(h, with: .color(guide), lineWidth: 1)
        }

        context.stroke(Path(r), with: .color(.white.opacity(0.9)), lineWidth: 2)

        // Bold corner brackets so it's obvious the corners are draggable.
        let arm = min(28, min(r.width, r.height) / 3)
        let w: CGFloat = 6
        func bracket(_ corner: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            var p = Path()
            p.move(to: corner); p.addLine(to: CGPoint(x: corner.x + dx, y: corner.y))
            p.move(to: corner); p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
            context.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        bracket(CGPoint(x: r.minX, y: r.minY), arm, arm)
        bracket(CGPoint(x: r.maxX, y: r.minY), -arm, arm)
        bracket(CGPoint(x: r.minX, y: r.maxY), arm, -arm)
        bracket(CGPoint(x: r.maxX, y: r.maxY), -arm, -arm)
    }

    /// Crops the source image to the on-screen selection, mapping back to pixels via `imageRect`.
    private func cropImage(selection: CGRect) -> UIImage {
        guard imageRect.width > 0, imageRect.height > 0 else { return image }
        let upright = image.normalizedOrientation()
        let sx = upright.size.width / imageRect.width
        let sy = upright.size.height / imageRect.height
        let x = max((selection.minX - imageRect.minX) * sx, 0)
        let y = max((selection.minY - imageRect.minY) * sy, 0)
        let w = min(selection.width * sx, upright.size.width - x)
        let h = min(selection.height * sy, upright.size.height - y)
        guard w >= 1, h >= 1, let cg = upright.cgImage?.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
            return upright
        }
        return UIImage(cgImage: cg)
    }
}

nonisolated extension UIImage {
    /// Returns the image redrawn upright, so its cgImage matches what's on screen.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Writes the picture as a JPEG into the caches and returns its URL, ready for the OCR pipeline.
    func savedToCaches() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crops", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("crop_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        guard let data = jpegData(compressionQuality: 0.95) else {
            throw UserMessageError(message: "Couldn't save the picture.")
        }
        try data.write(to: url)
        return url
    }
}

/// The system camera, wrapped for SwiftUI. Returns the captured picture.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImage(nil)
        }
    }
}
