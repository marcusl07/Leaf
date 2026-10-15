# Leaf Kindle sync test

This test build includes everything Leaf needs for native Kindle USB sync.
No Homebrew, terminal commands, or separate file-transfer app are required.
It supports macOS 13 or later. This is an ad-hoc signed beta, not a notarized release.

1. Quit any existing Leaf build. Close Amazon USB File Manager, OpenMTP,
   Calibre, and other apps that might hold the Kindle connection.
2. Extract the ZIP and copy Leaf.app to Applications. Right-click Leaf and
   choose Open for the first launch, using the same beta installation steps
   as before. Open Leaf's Library to see import status.
3. Connect your Kindle with a data-capable USB cable. Allow approximately
   15 seconds for detection, plus time to transfer and import. Record the
   status message and the number of highlights added. A large transfer or
   device timeout can take up to two minutes.
4. Leave it connected for a minute. Leaf should sync once for this connection;
   it should not keep importing or repeatedly reconnecting the Kindle.
5. Unplug the Kindle for **at least 30 seconds**, then reconnect. Repeat this
   three times without restarting the Kindle. Each successful reconnect should
   show a new sync time and **0 new highlights** if the clippings are unchanged.
   Leaf deliberately ignores brief USB resets; very quick replugging may count
   as the same connection.
6. Quit Leaf while the Kindle remains connected, then launch Leaf again.
   It should detect the already-connected Kindle and import with no duplicates.
7. Leave the Kindle connected while the Mac sleeps and wakes. It should stay
   responsive and should not sync the same connection again. Then disconnect
   for 30 seconds and reconnect to verify a new sync still works.

If a transfer fails, record the message, close any competing transfer app, and
disconnect for 30 seconds before reconnecting. Leaf makes one attempt per
connection to avoid repeatedly disturbing the device. If the Kindle becomes
unresponsive, record that before restarting it. Unplugging during a transfer
should leave Leaf responsive and show an error rather than importing a partial file.

Please return:

- Mac model/chip, macOS version, Kindle model, and firmware version if available.
- First-import count and whether highlights appeared in Library.
- Results of the three reconnects, app relaunch, and sleep/wake tests.
- Exact error text and whether any step needed a Kindle restart.

Do not send My Clippings.txt, database files, or raw highlight contents.
Testing an older Kindle that mounts in Finder is also useful if one is available.

# Developer build

Install Xcode, XcodeGen, and pkg-config/pkgconf for development. Build dependencies
once per architecture; end users do not install these tools:

```sh
scripts/build_mtp_dependencies.sh "$PWD/Build/MTPDependencies/arm64" arm64
scripts/build_mtp_dependencies.sh "$PWD/Build/MTPDependencies/x86_64" x86_64
scripts/test_mtp.sh
scripts/package_mtp_beta.sh
```

The dependency script downloads pinned, checksum-verified source archives and
builds dynamic libraries for macOS 13. The archives, license notices, and rebuild
script are included inside the app. Set PKG_CONFIG to the pkgconf executable if
it is not installed under the pkg-config name. The package script builds both
architectures by default; set LEAF_BETA_ARCHS=arm64 for an Apple Silicon-only build.

The native process polls descriptors without opening MTP sessions, identifies an
Amazon PTP/MTP device by USB port topology, and makes one transfer attempt per
observed connection. Normal detection runs every 12 seconds; a disappearance
must be confirmed after an 8-second grace period. Brief disconnects/replugs can
be treated as the same connection. This avoids retry loops after the probe's
known USB cleanup reset. Opening Leaf starts a new app session and scans again.

USB work runs on a utility queue in a subprocess with a 120-second timeout and
forced termination fallback. Private temporary downloads are removed after
every import attempt; stale download directories older than 24 hours are pruned
at startup. The existing parser, database deduplication, and import status remain
the source of truth. Local tests cannot establish real-device reset/reconnect
reliability: that remains a hardware validation gate for this beta.

The standalone probe now shares Native/KindleMTPFileSearch.h. If packaging a new
comparison-probe archive from current sources, include that header with its
relative Native/ path alongside the scripts/ directory. The previously generated
comparison ZIP remains a historical probe, not the integrated beta app.
