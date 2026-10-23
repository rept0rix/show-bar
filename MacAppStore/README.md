# Mac App Store build

This is a separate, App Sandbox-enabled edition. It offers on-demand display capture and clipboard text history that is added only after the user presses a button. The direct-download edition in the repository root remains separate and unchanged.

## Open and build

Open `ShowBarStore.xcodeproj` in Xcode and select the `ShowBarStore` scheme. The Release configuration produces a universal macOS app (Apple Silicon and Intel), with a minimum deployment target of macOS 14.

The archive needs an Apple Developer Program account signed into Xcode, the app's registered bundle identifier, and an App Store provisioning profile. Set the correct Team under Signing & Capabilities, then choose Product → Archive. Submit the resulting archive from Xcode Organizer to App Store Connect.

`APP_STORE_METADATA.md` contains the listing copy and review notes. The privacy-policy and support pages are in `../site/privacy.html` and `../site/support.html`, and both are published on GitHub Pages. Capture product screenshots from the final signed build before submission.
