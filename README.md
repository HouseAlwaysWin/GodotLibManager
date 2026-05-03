# Godot Lib Manager

An editor plugin for **Godot 4** that lets you browse GitHub repositories (via optional JSON registries and manual repo lists), inspect releases, download `.zip` assets, and install addons under `res://addons/`—without using the Godot Asset Library.

## Requirements

- **Godot 4.6** (Forward Plus; other 4.x versions may work but are not explicitly verified here)

## Installation

### From a GitHub Release (recommended)

1. Open the [Releases](https://github.com/HouseAlwaysWin/GodotLibManager/releases) page for this repository.
2. Download `GodotLibManager_vX.Y.Z.zip`.
3. Extract the archive **into your Godot project root** so that you get:
   - `addons/godot_lib_manager/…`
4. Open the project in Godot.
5. Go to **Project → Project Settings → Plugins**, enable **Godot Lib Manager**, and click **Close**.

The plugin adds a **Lib Manager** entry on the editor’s main screen toolbar (alongside 2D, 3D, Script, …). Select it to open the UI.

### From a clone of this repository

If you are running this repo as a development project, the plugin is already under `addons/godot_lib_manager/`. Enable it under **Project Settings → Plugins** as above.

## First-time configuration

Open **Lib Manager** and click **Settings** (or use the settings entry in the UI, depending on layout):

| Setting | Purpose |
|--------|---------|
| **GitHub token** | Optional. Unauthenticated requests are subject to GitHub’s low API rate limit; a [personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) increases the limit. Stored in `user://godot_lib_manager.cfg` (not in the project folder). |
| **Registry URLs** | HTTP(S) URLs pointing to JSON registry files (see [Registry format](#registry-format)). Multiple URLs are merged; duplicate `owner/repo` entries are deduplicated. |
| **Manual repositories** | One GitHub repo per line: `owner/repo` or a full URL like `https://github.com/owner/repo`. These are listed without needing a registry file. |

Use **Save** (or the dialog’s save/close control) to persist settings.

## Using Lib Manager

### Plugin list and refresh

- **Refresh** reloads the combined list from your configured registries and manual repos (requires network for registry URLs).
- Select an entry in the list to see details: description, **Open repository**, release picker, and actions.

### Browse catalog (GitHub Search)

- **Browse catalog** / search uses GitHub’s API to discover repos tagged with common Godot-related topics (e.g. `godot-addon`, `godot-plugin`).
- Use the search box and filters (name, owner, description, fuzzy name) to narrow results. Pagination moves through result pages.
- **Add to my list** can add a discovered repo to your manual list (then appears on the next refresh).

### Installing, updating, and removing addons

1. Select a plugin/repo and choose a **release** from the dropdown.
2. **Install** downloads the best matching `.zip` release asset (or falls back when needed). The archive must contain an `addons/` layout at the root after normalization, or the installer may try to locate `plugin.cfg` and install under `res://addons/<folder>/`.
3. **Update** moves you to a newer release when an install is already recorded for that source.
4. **Uninstall** removes the tracked addon folders for that source (confirm in the dialog).

Release notes and rate-limit status are shown in the panel when available.

### Typical zip layout

For predictable installs, publish release zips where the inner paths include:

```text
addons/<your_plugin_name>/plugin.cfg
addons/<your_plugin_name>/…
```

If the zip only wraps a single addon without a top-level `addons/` folder, the installer may still detect `plugin.cfg` and install under a generated folder name—see on-screen error messages if something fails.

## Registry format

Registry JSON can be either:

**Object with a `plugins` array:**

```json
{
  "version": 1,
  "plugins": [
    {
      "name": "My Plugin",
      "owner": "github-user",
      "repo": "my-godot-addon",
      "description": "Short description.",
      "addon_dir": "optional_hint_for_zip_matching",
      "repo_html_url": "https://github.com/github-user/my-godot-addon"
    }
  ]
}
```

**Or a bare JSON array** of the same plugin objects.

Fields:

| Field | Required | Notes |
|-------|----------|--------|
| `owner`, `repo` | Yes | GitHub owner and repository name. |
| `name` | No | Display name; defaults to `owner/repo`. |
| `description` | No | Shown in the list/detail panel. |
| `addon_dir` | No | Hint used when picking a `.zip` asset whose filename should match a folder name. |
| `repo_html_url` | No | Defaults to `https://github.com/<owner>/<repo>`. |

An empty example ships at `addons/godot_lib_manager/example_registry.json`.

## Packaging and releases (maintainers)

This repo includes automation to ship only the addon folder inside a zip suitable for users (`addons/godot_lib_manager/…`).

- **GitHub Actions**: Pushing a tag `v*` builds `GodotLibManager_vVERSION.zip` and attaches it to a GitHub Release. The `version` in `addons/godot_lib_manager/plugin.cfg` must match the release version.
- **Locally (Windows)**: From the repo root, run `.\tools\release.ps1` to build into `dist\`, or `.\tools\release.ps1 1.2.3` to bump version, commit `plugin.cfg`, tag, and push (see script header for options such as `-ZipOnly`).

Workflow details: `.github/workflows/release.yml`.

## Troubleshooting

- **Rate limit**: Add a GitHub token in Settings or wait until the reset time shown in the panel.
- **`zip_contains_no_addons_folder`**: The release zip does not contain a usable `addons/` tree or discoverable `plugin.cfg`; fix the published archive or project layout.
- **Registry load errors**: Check the URL, JSON syntax, and that `owner`/`repo` are set for each plugin entry.