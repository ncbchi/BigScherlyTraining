import SwiftUI

// AsyncImage can't attach an Authorization header, so protected image endpoints
// (e.g. /admin/photos/{id}/file, which requires a trainer JWT) come back 401 and
// render as a broken placeholder. AuthedAsyncImage fetches the bytes itself with
// the bearer token attached, then shows the decoded image.
struct AuthedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: (Bool) -> Placeholder   // Bool = failed (vs still loading)

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder(failed)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { failed = true; return }
        var req = URLRequest(url: url)
        if let token = APIClient.shared.token(for: url.path) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let ui = UIImage(data: data) else {
                await MainActor.run { failed = true }
                return
            }
            await MainActor.run { image = ui }
        } catch {
            await MainActor.run { failed = true }
        }
    }
}
