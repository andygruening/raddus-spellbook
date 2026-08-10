# Publishing Spellbook for macOS

Use Xcode for signing, archiving, and notarizing the app. Use GitHub Releases to host the final `.dmg`.

## One-Time Xcode Setup

1. Open `Spellbook.xcodeproj` in Xcode.
2. Select the `Spellbook` project in the navigator, then the `Spellbook` target.
3. Open **Signing & Capabilities**.
4. Select your paid Apple Developer Program team.
5. Keep **Automatically manage signing** enabled.
6. Confirm the bundle identifier is `com.raddus.spellbook`.
7. Confirm **Hardened Runtime** is enabled.
8. Confirm **App Sandbox** is enabled with outgoing network access and user-selected read/write file access.

The project is set up for Xcode-managed signing. The Team field is intentionally not committed because it comes from your local Apple Developer account.

## Archive and Export

1. In Xcode, select **Any Mac** as the run destination.
2. Choose **Product > Archive**.
3. In Organizer, select the new archive.
4. Click **Distribute App**.
5. Choose **Direct Distribution**. If Xcode shows the custom flow instead, choose **Developer ID**.
6. Let Xcode handle signing and notarization.
7. Export the notarized app locally.

Xcode exports the signed/notarized app, but it does not create a GitHub-ready `.dmg` release asset. Put the exported `Spellbook.app` into a disk image before uploading it.

## Create the DMG

After exporting from Xcode, create a disk image with Finder, Disk Utility, or `hdiutil`. A typical release asset name is:

```text
Spellbook-0.1.0.dmg
```

Before publishing, test the exported app and the `.dmg` on a machine or macOS user account that does not already have a development build installed.

## Upload to GitHub

1. Open the GitHub repository.
2. Go to **Releases**.
3. Draft a new release.
4. Use a tag that matches the app version, such as `v0.1.0`.
5. Upload `Spellbook-0.1.0.dmg` as a release asset.
6. Publish the release.
