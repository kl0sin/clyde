# Release process

How to cut a new Clyde release. The process is fully automated via
GitHub Actions — your job is to bump the version and push a tag.

## One-time setup

These steps only need to happen once, before the first release.

### 1. Apple Developer Program

Confirm an active Developer Program membership ($99/year). You'll need:

- An **Apple ID** with the membership attached
- Your **Team ID** (10 chars, in the membership details page)
- A **Developer ID Application** certificate
- An **app-specific password** for `notarytool`

### 2. Create the Developer ID Application certificate

In the [Apple Developer portal](https://developer.apple.com/account/resources/certificates):

1. Certificates → click **+**
2. Pick **Developer ID Application**
3. Upload a CSR generated locally via Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority. Save to disk.
4. Download the resulting `.cer` file, double-click to install in Keychain Access.

### 3. Export the cert as `.p12` for CI

In Keychain Access → My Certificates, find the new "Developer ID Application: ..." entry, right-click → Export → save as `developer-id.p12` with a strong password.

Encode it for the GitHub Secret:

```bash
base64 -i developer-id.p12 | pbcopy
```

### 4. Generate the app-specific password

[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords → **+** → label it "Clyde notarization".

### 5. Generate the Sparkle EdDSA keypair

Sparkle ships its tools alongside the framework. After the first SPM build, run:

```bash
swift build
find .build -name 'generate_keys' -type f
# Found at: .build/.../Sparkle/.../generate_keys
./.build/.../generate_keys
```

It writes the public key to stdout (paste into `Clyde/Info.plist` →
`SUPublicEDKey`) and stores the private key in your default Keychain.

To extract the private key for the GitHub Secret:

```bash
./.build/.../generate_keys --account default -p
```

### 6. GitHub Secrets

Repo → Settings → Secrets and variables → Actions → **New repository secret**.

Add all of these:

| Name | Value |
|------|-------|
| `DEVELOPER_ID_CERT_P12_BASE64`  | base64 of the exported `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD`    | password you used when exporting the .p12 |
| `DEVELOPER_ID_APPLICATION`      | full identity name, e.g. `Developer ID Application: Mateusz Kłosiński (ABCD123456)` |
| `APPLE_ID`                      | Apple ID email |
| `APPLE_TEAM_ID`                 | 10-char team ID |
| `APPLE_APP_PASSWORD`            | app-specific password from step 4 |
| `SPARKLE_PRIVATE_KEY`           | EdDSA private key from step 5 |

### 7. Enable GitHub Pages

Repo → Settings → Pages → Source: **GitHub Actions**.

The first push to `main` triggers `deploy-site.yml` and the landing page +
`appcast.xml` go live at `https://kl0sin.github.io/clyde/`.

---

## Cutting a new release

Day-to-day flow once the setup above is in place:

1. **Bump the version** in `Clyde/Info.plist` (`CFBundleShortVersionString`).
2. **Add a section to `CHANGELOG.md`** describing what's new — Sparkle
   shows this directly inside the "Update available" sheet, so write it
   for end users.
3. **Commit + push:**

   ```bash
   git add Clyde/Info.plist CHANGELOG.md
   git commit -m "release: 0.2.0"
   git push
   ```

4. **Tag and push the tag:**

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

5. The `release.yml` workflow runs automatically and:
   - builds a universal `Clyde.app`
   - signs it with your Developer ID
   - notarizes via Apple
   - packs it into `Clyde-0.2.0.dmg`
   - generates a Sparkle EdDSA signature
   - inserts a new entry into `site/appcast.xml` and pushes back to `main`
   - re-deploys the landing page (via `deploy-site.yml`)
   - publishes a GitHub Release with the DMG attached

   Total wall time: ~10–15 minutes (notarization is the slow part).

6. **Update the Homebrew cask** (until automated):
   - Compute the DMG sha256: `shasum -a 256 Clyde-0.2.0.dmg`
   - Edit `Casks/clyde.rb` in your tap repo, bump version + sha256
   - Commit + push

Users running Clyde will see the update banner within 24 hours
automatically. Homebrew users get it on their next `brew upgrade`.

---

## Manual / local dry-run

If you want to test the build pipeline locally without pushing a tag:

```bash
scripts/release/build.sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (XXXXXXXXXX)" \
    scripts/release/sign.sh
APPLE_ID=you@example.com APPLE_TEAM_ID=XXXXXXXXXX APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
    scripts/release/notarize.sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (XXXXXXXXXX)" \
    scripts/release/make-dmg.sh
```

Resulting DMG: `build/release/Clyde-x.y.z.dmg`. Open it on a clean Mac to
verify Gatekeeper accepts the signed bundle.
