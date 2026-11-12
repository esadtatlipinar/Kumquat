# Kumquat local plugin host

The upstream Kumquat 1.0.4 release has no external plugin API. This local branch adds a deliberately small command-plugin boundary while keeping plugin files outside `Kumquat.app`.

## Discovery

Kumquat reads:

```text
~/Library/Application Support/Kumquat/Plugins/*/plugin.json
```

Manifest schema version `1` defines an id and actions. Every action has a title, SF Symbol, accepted file extensions, a relative executable path and arguments. The executable must resolve inside its plugin directory and must be executable. Invalid manifests are ignored.

Supported argument placeholders:

- `{input}` — absolute input path
- `{inputDirectory}` — input parent directory
- `{inputName}` — input filename

The command must print one JSON value to stdout:

```json
{"outputs":["/absolute/output/path"],"detail":"optional toast text"}
```

Kumquat verifies a zero exit status, parses the response, verifies every output exists, and then uses its normal progress, notification, Finder reveal and Undo paths. The original is never moved or overwritten by the host.

## Installed local plugin

`LocalPlugins/har-json-tools` contributes:

- `.har` → **HAR Minify**
- `.json` → **JSON LLM Ready**

Both write collision-safe outputs beside the input via the already verified `HAR Minifier/har_kucultucu.py` core. The installer snapshots that core into the plugin directory, so the wheel action does not depend on a running web UI.

## Install and update

```bash
scripts/install-local.sh
```

The installed custom build redirects Kumquat's **Update Now** action to:

```text
~/Library/Application Support/Kumquat/PluginHost/update.command
```

That command fetches upstream `main`, rebases the local plugin-host commit, runs the focused plugin tests, builds first, backs up the currently installed app, verifies the new signature, and only then replaces `/Applications/Kumquat.app`. If the rebase or build fails, the installed working app is left untouched.

The plugin directory is outside the app bundle and therefore survives every app replacement.
