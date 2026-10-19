# Spacekeeper

Free up space on your iPhone without losing a single photo.

Spacekeeper lists every photo and video with its size, biggest first, and moves
the ones you choose to a place that keeps them: Yandex Disk, Google Drive, or
a computer over the cable. An original leaves the iPhone only after its copy
has been checked byte for byte, and iOS still asks before anything is deleted.

Project page, privacy policy and support:
[etojesaandro.github.io/Spacekeeper](https://etojesaandro.github.io/Spacekeeper/).

## What it does

- **Library** — a grid like Photos, with each item's size on it; biggest first,
  or by date; by year and month, with what each period weighs.
- **Move, Copy or Delete only** — uploads run in the background and survive
  leaving the app. Files go into `YYYY/MM` folders and keep their capture dates.
- **Cloud** — browse what Yandex Disk or Google Drive keeps and restore
  originals, Live Photos included, back to Photos.
- **Backup to a computer** — over the cable to Windows, macOS or Linux, in the
  same year and month folders; running it again fetches only what is new.
- **Ten languages** — English, Russian, Ukrainian, German, Spanish, French,
  Italian, Portuguese (Brazil), Chinese (Simplified) and Japanese.

Nothing is sent anywhere but to the cloud or computer you choose. Google
access is limited to the files the app creates.

## Layout

| Path | What it is |
|---|---|
| `Sources/Spacekeeper` | The iOS app (SwiftUI, PhotoKit) |
| `Core` | Everything that does not need iOS: clouds, upload queue, backup, cable protocol; tested on Linux |
| `Core/Sources/SpacekeeperBackup` | `spacekeeper-backup`, the computer side of the cable backup |
| `Localization` | Translations and `strings.py`, which builds and checks them |

## Building

The app is developed without a Mac, with [xtool](https://github.com/xtool-org/xtool)
on Linux; it builds with Xcode as well.

```sh
cd Core && swift test          # the shared code's tests, on Linux or macOS
xtool dev run                  # build, sign and install on a plugged-in iPhone
```

The computer tool:

```sh
cd Core && swift build -c release --product spacekeeper-backup
Core/Scripts/pc-tool-builds.sh # Linux and both Mac builds; Windows builds on GitHub Actions
```

On the iPhone open the Backup tab, then on the computer run `spacekeeper-backup`
(optionally followed by a folder) and type the code the phone shows. It needs
Apple's cable service: built into macOS, part of Apple Devices or iTunes on
Windows, the `usbmuxd` package on Linux.

## Translations

English text is the key. After changing a text in the code, add it to every
file in `Localization/translations/` and run:

```sh
python3 -I Localization/strings.py build
```

It refuses to write anything while a language lacks a text or a translation's
placeholders differ from the code's.

## Licence

[MIT](LICENSE). The name and icon of the published app are not covered by the
licence; please give a fork of your own a name of its own.
