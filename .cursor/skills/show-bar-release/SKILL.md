---
name: show-bar-release
description: >-
  Bumps the Show Bar marketing version in every shipped place, builds the
  install disk, and publishes git, GitHub Pages, and the GitHub release.
  Use when releasing Show Bar, bumping the version, updating the site download,
  or when the user asks to update the version number everywhere.
---

# Show Bar release

One command stamps the version. Do not edit the number by hand in plist, README, or the site.

## Stamp

1. Write the new notes at the top of `CHANGELOG.md` before stamping.
2. Run `scripts/set-version.sh 1.3` (two or three numeric parts).
3. It prints `version`, `build`, `tag`, `dmg`, and `url`. Use those strings for the disk and the GitHub release. Do not invent a different filename.

The script updates `VERSION`, `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`), the `// showbar-version` fallback in `Sources/AppMain.swift`, the `<!-- showbar:download -->` block in `README.md`, and the same block in `site/index.html`.

`CFBundleVersion` always increases by one. The public tag is `v1.3.0` when the argument is `1.3`, and `v1.3.1` when the argument already has three parts. The disk name is `Show-Bar-1.3.dmg`.

## Resources

Before a version goes up, Show Bar has to stay cheap while it sits in the menu bar.

1. `scripts/check-resources.sh` must print `Resource check passed`. `scripts/build.sh` runs it and stops when it fails.
2. Install the build, leave Show Bar idle with the pointer away from the Dock, then run `scripts/check-resources.sh --live`. It must print `Live resource check passed`.
3. Idle timers stay at one second or slower. A faster timer is allowed only while a preview, a crop, or the permissions window is open, and that timer has to stop when the window closes.
4. An event tap turns off when the preview or Command-Tab closes. Screenshots held in memory stay at 8 or fewer. Clipboard history stays at 100 items or fewer.

## Ship

1. `scripts/build.sh` must print `Built`.
2. Build the disk from `build/Show Bar.app` with `hdiutil create -volname "Install Show Bar" -format UDZO`. Put a symlink to `/Applications` beside the app. Name the file exactly the printed `dmg`.
3. Commit on a branch named `v` plus the marketing version (`v1.3`). Push that branch. Fast-forward `main` and push it. Do not force-push `main`.
4. `gh release create` with the printed tag, title `Show Bar` plus the marketing version, and upload only that dmg.
5. Publish the site with `git subtree split --prefix site -b site-pages` and `git push origin site-pages:gh-pages`. Force that branch only when the split is not a fast-forward.
6. Install locally by copying the built app to `~/Applications/Show Bar.app` and signing it with `Apple Development: na0ryank0@gmail.com (9YUWNCN45U)`, identifier `com.naoryanko.showbar`.

## Rules that stay true

- The in-app updater may replace the app only after `codesign --verify` and a check that the bundle id is `com.naoryanko.showbar` and the team is `CM9QNMLQMQ`.
- Do not describe the download as notarized. It is a development signature and opens on the Mac it was signed on.
- Do not commit `build/`.
