import SwiftUI

// Full-screen photo viewer: loads the authed server image, supports pinch-to-zoom
// and double-tap, and dismisses via the X or swipe-down. Used from both the client
// and trainer photo grids.
struct FullScreenPhotoView: View {
    let url: URL?
    let localImage: UIImage?          // just-uploaded photo (client), shown instantly
    let caption: String?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    init(url: URL?, localImage: UIImage? = nil, caption: String? = nil) {
        self.url = url; self.localImage = localImage; self.caption = caption
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let localImage {
                    Image(uiImage: localImage).resizable().scaledToFit()
                } else {
                    AuthedAsyncImage(url: url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: { failed in
                        if failed {
                            VStack(spacing: 8) {
                                Image(systemName: "photo").font(.system(size: 40)).foregroundColor(BrandDark.mute)
                                Text("Couldn't load photo").font(BrandFont.body(13)).foregroundColor(BrandDark.mute)
                            }
                        } else {
                            ProgressView().tint(BrandDark.volt)
                        }
                    }
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { v in scale = min(max(lastScale * v, 1), 5) }
                    .onEnded { _ in lastScale = scale; if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } } }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { v in
                        if scale > 1 {
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                    }
                    .onEnded { v in
                        if scale > 1 {
                            lastOffset = offset
                        } else if v.translation.height > 100 {
                            dismiss()   // swipe down to close when not zoomed
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3)) {
                    if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    else { scale = 2.5; lastScale = 2.5 }
                }
            }

            // Close button + caption
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 20).padding(.top, 12)
                }
                Spacer()
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(BrandFont.body(13, .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.5)).clipShape(Capsule())
                        .padding(.bottom, 30)
                }
            }
        }
        .statusBarHidden()
    }
}
