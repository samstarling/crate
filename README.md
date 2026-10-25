# Crate

A fast, native macOS app for browsing and tidying your Rekordbox library.

Crate reads your Rekordbox 6 or 7 library directly from its database. You can browse your collection, playlists and smart playlists, preview tracks with their waveform, set track colours and remove tracks from the collection.

## Install

1. Download the latest `Crate-x.y.z.dmg` from [Releases](../../releases).
2. Open it and drag **Crate** into **Applications**.

Crate is signed and notarized by Apple, so it opens like any other app. It needs macOS 15.6 or later.

## Your library is safe, but read this

Crate **writes to Rekordbox's `master.db`** when you change colours or remove tracks. To keep that safe, it:

- refuses to make changes while Rekordbox is running, and
- backs up `master.db` before every change, to `~/Library/Application Support/Crate/Backups/`.

To restore a backup, quit Rekordbox and copy the backed-up files back into `~/Library/Pioneer/rekordbox/`. Rekordbox's database format isn't documented, so you should keep your own backups too.

## Building from source

You'll need Xcode 26 or later.

```sh
git clone https://github.com/samstarling/Crate.git
cd Crate
open Crate.xcodeproj
```

To sign with your own team, create `Config/Local.xcconfig` (it's git-ignored):

```
DEVELOPMENT_TEAM = YOURTEAMID
```

The Rekordbox reading and writing lives in a separate Swift package, `Packages/RekordboxKit`. You can test it with `swift test` from that folder.

## Contributing

Commits follow [Conventional Commits](https://www.conventionalcommits.org/), which is how releases get their version numbers:

| Prefix | Example | Release |
| --- | --- | --- |
| `fix:` | `fix: read Date Added from StockDate` | patch |
| `feat:` | `feat: show smart playlists` | minor |
| `feat!:` or a `BREAKING CHANGE:` footer | `feat!: drop Rekordbox 6 support` | major |

`docs:`, `refactor:`, `test:`, `ci:`, `chore:` and others don't trigger a release on their own. To have Git check your messages, run:

```sh
git config core.hooksPath .githooks
```

## Releasing

Releases are automated with [release-please](https://github.com/googleapis/release-please):

1. Every push to `main` updates an open **Release PR** with the next version number and a changelog.
2. Merging that PR tags the release and creates a GitHub Release.
3. CI then builds the app, signs it with Developer ID, notarizes and staples it, and attaches a `.dmg` and a `.zip`.

## Licence

[MIT](LICENSE). Crate uses [SQLCipher](https://www.zetetic.net/sqlcipher/) (BSD licence). The acknowledgements are in the app's About window.

Crate isn't affiliated with or endorsed by AlphaTheta or Pioneer DJ. Rekordbox is a trademark of AlphaTheta Corporation.
