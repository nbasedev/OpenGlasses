# Local signing changes

Personal-signing adjustments for team **8J4Y9HQJQW** (NorthBase Ltd).
Not upstream changes — do not send these in a PR to `straff2002/OpenGlasses`.

Built and installed successfully on 2026-09-12 (iPhone 14 Pro, iOS 26.6.1,
Xcode 26.6) as bundle `com.northbase.openglasses`.

## What changed and why

| File | Change | Reason |
|---|---|---|
| `project.local.yml` (gitignored) | Team ID on all 6 targets; own bundle IDs; entitlements overrides | Upstream bundle IDs belong to another team |
| `project.base.yml` | Removed `carplay-voice-based-conversation`; app group → `group.com.northbase.openglasses` | CarPlay voice needs per-team Apple approval; the old app group isn't ours |
| `*/*.entitlements` (3 files) | Same two changes | XcodeGen **merges** its `entitlements:` block into these files rather than replacing them, so the committed values had to change too |

## The gotcha that cost the most time

Overriding `CODE_SIGN_ENTITLEMENTS` in `project.local.yml` does **nothing**:
`project.base.yml` declares an XcodeGen `entitlements:` block with inline
`properties:`, which regenerates the `.entitlements` file on every
`generate-xcodeproj.sh` run and overwrites manual edits. The merge is additive,
so an override in `project.local.yml` *adds* a second app group rather than
replacing the first, and cannot remove a key at all.

The fix is to edit `project.base.yml` (and the committed `.entitlements`
files) directly.

## Bundle identifiers

```
com.northbase.openglasses                       # app
com.northbase.openglasses.GlassesActivityWidget # widget
com.northbase.openglasses.ShareExtension        # share extension
com.northbase.openglasses.watchkitapp[.widget]  # watch
group.com.northbase.openglasses                 # app group
```

## Rebuild

```bash
bash Scripts/generate-xcodeproj.sh
xcodebuild -project OpenGlasses.xcodeproj -scheme OpenGlasses \
  -destination "id=<device-udid>" -configuration Debug \
  -allowProvisioningUpdates build
```

## Still outstanding

1. **Meta credentials** — `MWDAT_META_APP_ID` and `MWDAT_CLIENT_TOKEN_HASH` in
   `project.local.yml` are still placeholders. Until they're real, DAT
   registration never completes and **Connect appears to do nothing** (the
   camera permission prompt is gated behind registration).
2. **Universal Links** — needs a domain hosting
   `/.well-known/apple-app-site-association`.
3. **Patches P1–P4** — see `../META-CLAUDE.md` §3.

## Merging upstream later

`project.base.yml` and the three `.entitlements` files will conflict on every
upstream change to them. Keep this diff small and re-apply after a merge.
