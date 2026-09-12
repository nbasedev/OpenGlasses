# Restore the known-good build

Snapshot of the state confirmed working by voice on 2026-09-12: iPhone 14 Pro
(iOS 26.6.1), wake word → speech recognition → Anthropic → TTS through the
glasses.

| Where | What |
|---|---|
| `git tag working-2026-09-12` (commit `f257d76`) | All source, entitlements and signing config |
| `~/.meta-claude/backup-2026-09-12/project.local.yml` | Meta credentials + team ID (gitignored, so not in the tag) |
| `~/.meta-claude/backup-2026-09-12/bridge-config.json` | Bridge token and project allowlist |
| `~/.meta-claude/backup-2026-09-12/OpenGlasses.app.tar.gz` | The exact 71 MB binary installed on the phone |

## Fastest: reinstall the archived binary

No rebuild, no Xcode. Gets the phone back to the known-good app in a minute.

```bash
cd ~/.meta-claude/backup-2026-09-12
tar xzf OpenGlasses.app.tar.gz
xcrun devicectl device install app \
  --device 4E28ED00-FE43-5346-87F0-8BC866C157FB \
  OpenGlasses.app
```

## Full: restore the source and rebuild

```bash
cd ~/Development/Workspace/Meta/openglasses
git stash                                   # keep anything uncommitted
git checkout working-2026-09-12
cp ~/.meta-claude/backup-2026-09-12/project.local.yml .
bash Scripts/generate-xcodeproj.sh
xcodebuild -project OpenGlasses.xcodeproj -scheme OpenGlasses \
  -destination "id=4E28ED00-FE43-5346-87F0-8BC866C157FB" \
  -configuration Debug -allowProvisioningUpdates build
```

Then install as above, or let Xcode do it.

## Return to the latest work

```bash
git checkout main
```

The tag is a fixed point in history — later commits do not move or change it.

## Restore the bridge config

```bash
cp ~/.meta-claude/backup-2026-09-12/bridge-config.json ~/.meta-claude/config.json
launchctl kickstart -k gui/$(id -u)/com.metaclaude.bridge
```

## What is NOT covered

- **Meta Wearables Developer Center settings** (bundle ID, team ID, camera
  permission) live on Meta's servers. Unchanged by anything local.
- **In-app settings** — API key, personas, harness URLs — live in the app's
  own storage on the phone. Reinstalling over the top normally preserves them;
  deleting the app does not.
- **Glasses pairing** in the Meta AI app.

## If something breaks later

Reinstalling the archived binary is the quickest way to find out whether a
problem is the app or something else (bridge, network, credentials). If the
old binary works and the new one doesn't, the change is at fault; if both
fail, look at the bridge or the glasses connection instead.
