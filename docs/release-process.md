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

Easiest path is through Xcode (it handles the CSR for you):

1. Xcode → Settings → **Accounts** → sign in with the Apple ID that
   holds the Developer Program membership.
2. Select the team → **Manage Certificates…**
3. Bottom-left **+** → **Developer ID Application**.

The cert + private key land in your login Keychain. Verify with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see one entry like `Developer ID Application: Your Name (ABCD123456)`.

_Alternative (portal + manual CSR):_ [Apple Developer portal](https://developer.apple.com/account/resources/certificates)
→ Certificates → **+** → Developer ID Application → upload a CSR
generated via Keychain Access → Certificate Assistant → Request a
Certificate from a Certificate Authority. Download the `.cer`,
double-click to install. Use this path only if Xcode is unavailable.

### 3. Export the cert as `.p12` for CI

Open **Keychain Access** (on recent macOS it's hidden — `open
/System/Applications/Utilities/Keychain\ Access.app`). Select the
**login** keychain, Category → **My Certificates** (must be *My*
Certificates, otherwise the private key is missing and the export is
useless). Right-click the "Developer ID Application: …" entry →
Export → save as `developer-id.p12` with a strong password.

Encode it for the GitHub Secret:

```bash
base64 -i developer-id.p12 | pbcopy
```

If `base64` errors with `Operation not permitted`, macOS TCC is
blocking your terminal's access to the folder. Move the file to
`/tmp` first (or grant the terminal Desktop/Documents access in
System Settings → Privacy & Security → Files and Folders).

### 4. Generate the app-specific password

[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords → **+** → label it "Clyde notarization".

### 5. Generate the Sparkle EdDSA keypair

Sparkle ships its tools alongside the framework. After the first SPM
build, the binary lives at
`.build/artifacts/sparkle/Sparkle/bin/generate_keys`.

**First-time generation** (only if `SUPublicEDKey` is not yet set in
`Clyde/Info.plist`):

```bash
swift build   # fetches Sparkle into .build
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It prints the public key to stdout (paste into `Clyde/Info.plist` →
`SUPublicEDKey`) and stores the private key in your login Keychain
under `https://sparkle-project.org`.

**Export the private key for the GitHub Secret:**

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle-private.pem
cat /tmp/sparkle-private.pem            # 44-char base64, copy this
rm /tmp/sparkle-private.pem             # do not leave it on disk
```

**Verify the private key matches the public key in Info.plist** (before
wiring it to CI — a mismatch means Sparkle will silently reject every
update):

```bash
echo -n test > /tmp/sparkle-check.bin
.build/artifacts/sparkle/Sparkle/bin/sign_update /tmp/sparkle-check.bin
rm /tmp/sparkle-check.bin
```

If it emits a `sparkle:edSignature="…"` line, the Keychain key and the
`SUPublicEDKey` in Info.plist match. If it errors or prompts for a key,
they've diverged — rotate both sides.

### 6. GitHub Secrets

Repo → Settings → Secrets and variables → Actions → **New repository secret**.

Add all of these:

| Name | Value |
|------|-------|
| `DEVELOPER_ID_CERT_P12_BASE64`  | base64 of the exported `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD`    | password you used when exporting the .p12 |
| `DEVELOPER_ID_APPLICATION`      | full identity name, e.g. `Developer ID Application: Your Name (ABCD123456)` |
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

1. **Add a section to `CHANGELOG.md`** describing what's new — Sparkle
   shows this directly inside the "Update available" sheet, so write
   it for end users.
2. **Commit + push:**

   ```bash
   git add CHANGELOG.md
   git commit -m "release: 0.2.1"
   git push
   ```

3. **Tag and push the tag:**

   ```bash
   git tag v0.2.1
   git push origin v0.2.1
   ```

4. The `release.yml` workflow runs automatically and:
   - stamps `CFBundleShortVersionString` from the tag and
     `CFBundleVersion` from the workflow run number (the tag is the
     single source of truth — no need to edit `Info.plist` by hand)
   - builds a universal `Clyde.app`
   - signs it with your Developer ID
   - notarizes via Apple
   - packs it into `Clyde-0.2.1.dmg`
   - generates a Sparkle EdDSA signature
   - inserts a new entry into `site/appcast.xml` and pushes back to `main`
   - re-deploys the landing page (via `deploy-site.yml`)
   - publishes a GitHub Release with the DMG attached

   Total wall time: ~10–15 minutes (notarization is the slow part).

   **Branch protection caveat:** the appcast push step runs as
   `github-actions[bot]` and hits `main` directly. If `main` has a
   protection rule that blocks bot pushes (required reviews, linear
   history, required status checks), this step will fail — the signed
   DMG still lands on the GitHub Release, but `site/appcast.xml` stays
   stale. Recovery: pull the step's `<item>` block from the workflow
   log, open a PR adding it to `site/appcast.xml` manually. Long-term
   fix tracked in the roadmap.

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
