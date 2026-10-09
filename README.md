# Leaf

Leaf is a lightweight, set-and-forget macOS menu bar utility that brings your Kindle highlights to life on your desktop. It automatically monitors when your Kindle is connected, parses your highlights from `My Clippings.txt`, overlays them onto beautiful background images of your choice, and cycles them as your desktop wallpaper on a customizable schedule.

---

## Public Beta

Leaf is currently in a public validation beta. We are gathering feedback to understand how you interact with the app and what features you would like to see next.

### Installation

Because Leaf is currently in public beta, it is distributed directly as an unsigned/unnotarized build. To install and run the app, please follow these steps:

1. **Download**: Download the latest release package (`Leaf.dmg` or `Leaf.zip` containing `Leaf.app`) from the [GitHub Releases](https://github.com/marcusl07/KindleWallpaper/releases) page.
2. **Extract & Move**: Extract the zip file (if applicable) and drag `Leaf.app` into your **/Applications** folder.
3. **Bypass Gatekeeper (First Launch)**:
   - Do **not** double-click the app to open it for the first time, as macOS Gatekeeper will block unsigned applications.
   - Instead, **right-click (or Control-click) `Leaf.app`** in your `/Applications` folder and select **Open**.
   - A dialog box will appear asking if you are sure you want to open it. Click **Open**.
   - Alternatively, if you double-clicked it and got blocked, go to **System Settings > Privacy & Security**, scroll down to the Security section, and click **Open Anyway**.
   - Subsequent launches will start normally without any prompts.

### Privacy & Local-Data Policy

Leaf respects your privacy completely. The app is built with a local-first architecture:
* **100% Local Storage**: All your highlight clippings, books list, and wallpaper settings are stored locally on your Mac inside a SQLite database.
* **No Cloud / No Sync**: There are no remote user accounts, no cloud databases, and no sync features. Your reading highlights never leave your machine.
* **No Analytics or Telemetry**: Leaf does not contain trackers, telemetry, or analytics. There are no background pings or remote logging unless explicitly introduced in a future release with your clear opt-in consent.

### Known Limitations

As an early public beta, Leaf has some known limitations:
* **Must Remain Running**: For scheduled wallpaper rotations (e.g., every 30 minutes, or daily at 9:00 AM) to fire, the Leaf application must be running. You can enable **Launch at Login** in the settings window under the *About* section to ensure it runs automatically.
* **Single Monitor Centering**: When multiple monitors are connected, Leaf sets the same generated wallpaper on all active displays.
* **English-only Kindle Parsing**: The highlight parser is designed to read standard English-language clipping formats from `My Clippings.txt`. Sideloaded books or non-English clipping formats may have limited parsing support.

---

## License

Leaf is distributed under the terms of the license details accompanying this repository.

## Developer Handoff

See [Kindle MTP findings and next steps](kindle-mtp-autosync-findings.html) for the October 9, 2026 successful native download, the API mismatch fix (`f7d14fd`), reproduction steps, and remaining Leaf integration work.
