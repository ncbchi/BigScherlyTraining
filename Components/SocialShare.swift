import UIKit

// Routes a rendered share card to the right destination.
//
// Instagram & Facebook expose a Stories URL scheme: you put the image on the system
// pasteboard under their agreed keys, then open "<app>-stories://share". The app launches
// straight into its Story composer with the image as the background layer — no share sheet.
//
// TikTok / X / Threads / Bluesky do NOT offer any equivalent for handing them a
// pre-rendered image, so those fall back to the iOS share sheet (handled by the caller).
enum SocialTarget {
    case instagram, facebook, systemSheet

    var canDeepLink: Bool { self != .systemSheet }
}

enum SocialShare {
    // Facebook's Stories API requires an app id in the pasteboard payload. Instagram's
    // does not for a plain background image. If you register a Facebook app, drop its id here.
    static let facebookAppID = ""   // optional; empty still opens FB, just without attribution

    static func isAvailable(_ target: SocialTarget) -> Bool {
        switch target {
        case .instagram:
            return UIApplication.shared.canOpenURL(URL(string: "instagram-stories://share")!)
        case .facebook:
            return UIApplication.shared.canOpenURL(URL(string: "facebook-stories://share")!)
        case .systemSheet:
            return true
        }
    }

    /// Push the card into Instagram/Facebook's Story composer. Returns false if the app
    /// isn't installed (caller can then fall back to the share sheet).
    @discardableResult
    static func shareToStory(_ image: UIImage, target: SocialTarget) -> Bool {
        guard let data = image.pngData() else { return false }

        let scheme: String
        let pasteboardItems: [String: Any]
        switch target {
        case .instagram:
            scheme = "instagram-stories://share?source_application=bigscherlytraining"
            pasteboardItems = ["com.instagram.sharedSticker.backgroundImage": data]
        case .facebook:
            scheme = "facebook-stories://share"
            var items: [String: Any] = ["com.facebook.sharedSticker.backgroundImage": data]
            if !facebookAppID.isEmpty { items["com.facebook.sharedSticker.appID"] = facebookAppID }
            pasteboardItems = items
        case .systemSheet:
            return false
        }

        guard let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) else { return false }

        // The pasteboard hand-off is only valid for a short window, so set it with an
        // expiration right before opening the app.
        UIPasteboard.general.setItems(
            [pasteboardItems],
            options: [.expirationDate: Date().addingTimeInterval(60 * 5)]
        )
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }
}
