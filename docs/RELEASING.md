# Releasing CapyBuddy (auto-update via Sparkle)

CapyBuddy ships outside the App Store and updates itself with
[Sparkle](https://sparkle-project.org). Existing installs poll an **appcast**
feed; when a newer build is published they show the familiar
"A new version is available" dialog and update on one click.

## How the pieces fit

| Piece | Where |
|-------|-------|
| Update feed (`appcast.xml`) | `docs/appcast.xml`, served by **GitHub Pages** at `https://atlai-tech.github.io/CappyBuddyOfficial/appcast.xml` |
| App download (`.zip`) | **GitHub Release asset** under tag `vX.Y.Z` |
| Feed URL the app reads | `SUFeedURL` in `CapyBuddy/App/CapyBuddyPro-Info.plist` (points at the Pages URL above) |
| Update signature | EdDSA, signed by the private key in the keychain; public key is `SUPublicEDKey` in the Info.plist |

## One-time setup

1. **GitHub Pages**: repo **Settings → Pages → Source = "Deploy from a branch",
   branch `main`, folder `/docs`**. (This `docs/` folder is the source.)
2. **Notary credentials**: `xcrun notarytool store-credentials CAPYBUDDY_NOTARY …`
   (see header of `scripts/release.sh`).
3. **Sparkle key check**: run `generate_keys -p` and confirm it prints the same
   value as `SUPublicEDKey` in the Info.plist. If it doesn't, the keychain is
   missing the matching private key and clients will reject every update.
4. *(Optional)* install & auth the GitHub CLI (`gh`) so releases upload
   automatically. Without it the script prints manual upload steps.

## Cutting a release

1. **Bump the version** in `CapyBuddy/App/CapyBuddyPro-Info.plist`:
   - `CFBundleShortVersionString` — marketing version (e.g. `2.0.1`); becomes the
     git tag `v2.0.1` and the Release title.
   - `CFBundleVersion` — **must increase every release** (e.g. `4` → `5`). Sparkle
     compares *this* number to decide whether an update exists. `release.sh`
     refuses to run if the current build number is already in the appcast.
2. Run the pipeline:
   ```sh
   ./scripts/release.sh
   ```
   It archives → notarizes → staples → zips → signs the appcast → uploads the
   zip to the GitHub Release (`vX.Y.Z`).
3. **Commit & push the feed** so Pages serves it:
   ```sh
   git add docs/appcast.xml CapyBuddy/App/CapyBuddyPro-Info.plist
   git commit -m "release: CapyBuddy X.Y.Z"
   git push
   ```

Within a few minutes GitHub Pages publishes the new feed and installed copies
pick up the update (or users can trigger it via **Settings → Check for Updates…**).

## Notes

- Older entries stay in `appcast.xml` so users one or two versions behind can
  still upgrade incrementally — don't prune it.
- The signed `.zip` lives under `releases/` locally (gitignored); the canonical
  copy is the GitHub Release asset.
