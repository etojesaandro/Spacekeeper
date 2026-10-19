# Releasing Spacekeeper from a Mac

Spacekeeper is developed on Linux with xtool, but App Store builds are made
with Xcode on a Mac. This guide takes a Mac from nothing to a TestFlight build
and then to App Review. Plan about two hours the first time and fifteen minutes
for later releases.

**Use the owner's Apple Developer account.** The bundle ID
`com.saa.spacekeeper` belongs to whichever team registers it first, and the
App Store shows that team as the seller. Signing with someone else's team
claims the ID for them. To try the build before the owner's account is ready,
change the bundle ID to something temporary such as
`com.<your-name>.spacekeeper.test` (step 4) and do not upload it.

## 1. Prepare the Mac (once)

1. Update macOS to the latest version.
2. Install **Xcode** from the Mac App Store. Open it once, accept the licence,
   and when asked which platforms to install, include **iOS**.
3. Open **Terminal** and check that Xcode is ready:

   ```sh
   xcrun -sdk iphoneos -show-sdk-path
   ```

   It should print a path ending in `iPhoneOS<version>.sdk`.
4. Install [Homebrew](https://brew.sh) if it is not there, then xtool:

   ```sh
   brew install xtool-org/tap/xtool
   ```

5. In Xcode, open **Settings › Accounts**, press **+**, choose **Apple ID** and
   sign in with the **owner's** Apple ID, the one with the paid membership.

## 2. Get the code

```sh
git clone https://github.com/etojesaandro/Spacekeeper.git
cd Spacekeeper
```

For a later release, update instead: `cd Spacekeeper && git pull`.

## 3. Make the Xcode project

```sh
xtool dev generate-xcode-project
open xtool/Spacekeeper.xcworkspace
```

The project is generated, not stored in the repository, so steps 4 and 5 are
repeated each time it is generated.

## 4. Set up the app target

In Xcode, select the **Spacekeeper** project in the left sidebar, then the
**Spacekeeper** target.

**Signing & Capabilities**
- Tick **Automatically manage signing**.
- **Team**: the owner's team.
- **Bundle Identifier**: `com.saa.spacekeeper`.

**General**
- **Supported Destinations**: iPhone only; remove iPad and Mac if listed.
- **Minimum Deployments**: iOS 17.0.
- **Version**: `1.0.0`. **Build**: `1`, raised by one for every upload; App Store
  Connect refuses a build number it has already seen.

## 5. Add the app icon

1. In the left sidebar, right-click the **Spacekeeper** group and choose
   **Add Files to "Spacekeeper"…**.
2. Pick `AppResources/Assets.xcassets` from the repository folder. Leave
   **Copy items if needed** off, and tick the **Spacekeeper** target.
3. Back in **General › App Icons and Launch Screen**, set **App Icon** to
   `AppIcon`.

## 6. Try it on an iPhone

1. Connect an iPhone with a cable, unlock it, and tap **Trust**. If iOS asks,
   turn on **Settings › Privacy & Security › Developer Mode** and restart.
2. Choose the iPhone in the device menu at the top of Xcode and press **Run**
   (▶︎).
3. Check that the app opens, reads the library, and that signing in to Yandex
   Disk and Google Drive works.

## 7. Create the app in App Store Connect (once)

1. Open [appstoreconnect.apple.com](https://appstoreconnect.apple.com) with
   the owner's Apple ID, then **Apps › + › New App**.
2. **Platform** iOS, **Name** Spacekeeper, **Primary language** English (U.S.),
   **Bundle ID** `com.saa.spacekeeper` (it appears after step 6 or step 8 has
   registered it), **SKU** `spacekeeper-ios`, **User access** Full.

## 8. Upload a build

1. In Xcode's device menu choose **Any iOS Device (arm64)**.
2. **Product › Archive**. When it finishes, the **Organizer** opens.
3. Select the new archive and press **Validate App**. This catches most
   problems before Apple's review does. Fix anything it reports and archive
   again.
4. Press **Distribute App › App Store Connect › Upload** and accept the
   defaults.
5. After 10–30 minutes the build appears in App Store Connect under
   **TestFlight**. Export compliance is already answered by the app (it uses
   only standard encryption).

## 9. Test with TestFlight

1. In **TestFlight › Internal Testing**, create a group, add the owner and
   friends, and add the build.
2. Testers install the **TestFlight** app on their iPhones and accept the
   invitation.
3. Use it for a few days: move, copy, delete, restore, back up to a computer,
   in more than one language.

## 10. Submit for review

In App Store Connect, open the app's **1.0** version and fill in:

| Field | What to enter |
|---|---|
| Name, subtitle, promotional text, keywords, description | From `AppStore/listing.json`, one block per language; add each language under **App Information › Localizable Information** |
| Screenshots | 6.9″ iPhone screenshots are required; take them on an iPhone 15 Pro Max or 16/17 Pro Max, or on the largest iPhone simulator in Xcode |
| Support URL | `https://etojesaandro.github.io/Spacekeeper/support/` |
| Marketing URL | `https://etojesaandro.github.io/Spacekeeper/` |
| Privacy Policy URL | `https://etojesaandro.github.io/Spacekeeper/privacy/` |
| Category | Photo & Video; secondary Utilities |
| Age rating | Answer "None" to every question |
| App Privacy | **Data Not Collected** |
| Price | Free |
| Build | The TestFlight build |

**App Review Information**: give a Yandex or Google test account with a few
photos in its Spacekeeper folder, and a note such as:

> Spacekeeper moves photos the user picks to the user's own Yandex Disk or
> Google Drive and deletes them from the iPhone only after the copy is
> verified; iOS asks to confirm every deletion. Sign in under the account
> button at the top left. The Backup tab needs a computer running the
> open-source spacekeeper-backup tool and is optional for review.

Then **Add for Review › Submit**. Review usually takes one to three days.

## If Apple says no

- **Guideline 2.5.1, non-public APIs**: the photo sizes are read through two
  undocumented PhotoKit properties (`ResourceWeight` in
  `Sources/Spacekeeper/DevicePhotos.swift`). Reply that they are read-only
  metadata, or switch to measuring sizes by reading the files.
- **Sign-in problems**: check that the Google OAuth client and the Yandex app
  list the bundle ID `com.saa.spacekeeper`.
- Anything else: copy the reviewer's message into an issue on GitHub.
