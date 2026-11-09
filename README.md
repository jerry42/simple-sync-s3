# Simple Sync S3 (S5)

[![CI](https://github.com/jerry42/simple-sync-s3/actions/workflows/ci.yml/badge.svg)](https://github.com/jerry42/simple-sync-s3/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/jerry42/simple-sync-s3)](https://github.com/jerry42/simple-sync-s3/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)

A small macOS menu bar app that backs up chosen local folders to an Amazon S3 bucket.

- **One-way sync, Mac → S3.** New and changed files are uploaded; nothing is ever downloaded or
  overwritten on your Mac.
- **Scheduled.** Every N minutes, at fixed times of day (missed times are caught up after sleep), at launch,
  or on demand from the menu.
- **Uses your existing AWS setup.** Named profiles from `~/.aws` (static keys, IAM Identity Center / SSO,
  `credential_process`, assume-role through the AWS CLI), or an access key whose secret lives in the macOS Keychain.
- **Safe by default.** Local deletions are only mirrored to S3 if you turn that on, and never for a folder
  synced to the bucket root or a local folder that is empty or missing (an unplugged external drive, for example).
- **`.gitignore`-style exclusions** per folder.
- **No dependencies.** Pure Swift / SwiftUI; the S3 client (SigV4) and the SSO login are written by hand
  on top of `URLSession` and CryptoKit.
- Optional **App Sandbox** build.
- **English and French.** The interface and the built-in help follow the macOS language (see [Languages](#languages)).

## Contents

- [Requirements](#requirements)
- [Download a release](#download-a-release)
- [Build and install](#build-and-install)
- [First-time setup](#first-time-setup)
- [Configuration reference](#configuration-reference)
- [Exclusions](#exclusions)
- [AWS credentials](#aws-credentials)
- [Minimal IAM policy](#minimal-iam-policy)
- [How syncing works](#how-syncing-works)
- [Costs and large folders](#costs-and-large-folders)
- [Sandboxed build](#sandboxed-build)
- [Command-line sync](#command-line-sync)
- [Languages](#languages)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Limitations](#limitations)
- [License](#license)

## Requirements

- macOS 13 Ventura or later (Apple silicon or Intel).
- To build from source: Swift 5.9 or later, from Xcode or just the Command Line Tools (`xcode-select --install`).
- An S3 bucket, and AWS credentials allowed to write to it (see [Minimal IAM policy](#minimal-iam-policy)).
- Optional: the [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
  only needed for profiles that use `role_arn` / `source_profile` (assume-role).

## Download a release

1. Download `SimpleSyncS3-<version>-macOS.zip` from the [latest release](https://github.com/jerry42/simple-sync-s3/releases/latest)
   and unzip it.
2. Move **Simple Sync S3.app** to `/Applications`.
3. The app is not notarized by Apple, so macOS blocks it the first time ("Apple could not verify…").
   Either open it once, then go to System Settings → Privacy & Security and click **Open Anyway**,
   or remove the quarantine flag in Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Simple Sync S3.app"
   ```

4. Open the app: a cloud icon appears in the menu bar. Continue with [First-time setup](#first-time-setup).

The downloaded app is signed *ad hoc*, so macOS asks again for access to your folders after each update
(see [Why the signing certificate?](#why-the-signing-certificate)). If that bothers you, build from source,
or re-sign the downloaded app with your own certificate after each update:

```bash
./scripts/create-signing-cert.sh    # once, from a clone of this repository
codesign --force --sign "Simple Sync S3 Local Signing" "/Applications/Simple Sync S3.app"
```

The release also contains the `s5-sync` [command-line tool](#command-line-sync) and a `SHA256SUMS.txt` file.

## Build and install

Building from source takes about a minute.

```bash
git clone https://github.com/jerry42/simple-sync-s3.git
cd simple-sync-s3

# Once: create a local code-signing certificate (recommended, see below)
./scripts/create-signing-cert.sh

# Build, copy to /Applications and launch
./scripts/install.sh
```

A cloud icon appears in the menu bar. Run `./scripts/install.sh` again after a `git pull` to update; it quits
the running copy first.

### Why the signing certificate?

Without a real certificate the app is signed *ad hoc*, and macOS only recognizes it by the exact hash of its
binary. Every rebuild then looks like a new app: macOS asks again for access to your Documents folder (and
to the Keychain), and syncing waits until you answer.

`scripts/create-signing-cert.sh` creates, once, a self-signed code-signing certificate named
**Simple Sync S3 Local Signing** in your login keychain (valid 10 years, never leaves your Mac).
`scripts/build-app.sh` picks it up automatically. To use another identity, such as an Apple Developer ID:

```bash
S5_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/install.sh
```

If you skip this step the app works, you will just see the permission prompts again after each update.

### Building without installing

```bash
./scripts/build-app.sh             # produces "build/Simple Sync S3.app"
./scripts/build-app.sh --sandbox   # App Sandbox variant, see "Sandboxed build"
open "build/Simple Sync S3.app"
```

## First-time setup

On first launch the app creates a template at
`~/Library/Application Support/SimpleSyncS3/config.json`. Then:

1. Click the menu bar icon → **Settings…** (⌘,).
2. **AWS Account** tab: pick a profile from `~/.aws` (the **Profiles** menu lists them), or enter
   an access key; then the bucket name and its region.
3. **Sync** tab: interval, fixed times, whether to mirror deletions, launch at login. Uncheck the interval
   or the fixed times to turn them off (an interval of `0` also means off); with both off, sync runs only at
   launch (if enabled) or with **Sync Now**.
4. **Folders** tab: **+** opens a folder picker. For each folder, set the S3 prefix and exclusions
   (one per line). A JSON mode lets you paste or edit the raw list.
5. **Save** (⌘S): the configuration is validated, written to `config.json` and reloaded.

If you use an access key, click **Secret Key…** in the settings, or the menu item
**Save AWS Secret Key…**, to store the secret in the Keychain.

If you use an IAM Identity Center (SSO) profile and are not logged in, the menu shows
**Sign In to AWS…**, see [IAM Identity Center](#iam-identity-center-sso).

The first sync starts according to your schedule, or right away with **Sync Now** (⌘S).
While it runs, the first menu line shows the current folder, a percentage and a file count,
e.g. `Photos: 37% (1250 / 3400)`.

Other menu items: **Open config.json** (open the file in a text editor), **Reload Configuration**
(⌘R, after editing the file by hand), **Open Log**, **Help** (built-in help page), **Quit Simple Sync S3**.

## Configuration reference

You can edit `~/Library/Application Support/SimpleSyncS3/config.json` directly instead of using the settings
window; the window keeps any keys it does not show. After editing by hand, use **Reload Configuration**
(the file is also re-read before each sync). See [`config.example.json`](config.example.json).

```json
{
  "awsProfile": "default",
  "region": "eu-west-3",
  "bucket": "my-backup-bucket",
  "deleteRemote": false,
  "launchAtLogin": false,
  "schedule": {
    "intervalMinutes": 60,
    "dailyTimes": ["02:00"],
    "syncOnLaunch": true
  },
  "folders": [
    { "localPath": "~/Documents/Invoices", "s3Prefix": "invoices", "exclude": ["*.tmp", "node_modules/"] },
    { "localPath": "~/Pictures/Scans" }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `awsProfile` | AWS profile to use. If omitted: `default`, unless `accessKeyId` is set (the access key is then used on its own). |
| `accessKeyId` | Access key used when no profile is set, or as a fallback when the profile fails. Its secret goes in the Keychain (or `secretAccessKey`). |
| `secretAccessKey` | Secret key in plain text in `config.json` (file created with mode `600`). Simpler, but the Keychain is safer and wins if it holds a secret. |
| `sessionToken` | Session token that goes with `accessKeyId` (temporary credentials only). |
| `region` | Bucket region. If omitted, taken from the profile in `~/.aws/config`. Required with a bare access key. |
| `bucket` | Bucket name. |
| `deleteRemote` | `true`: a file deleted locally is deleted from S3. Default `false`. |
| `launchAtLogin` | Start the app at login (only from the installed `.app`). |
| `schedule.intervalMinutes` | Sync every N minutes, counted from the end of the previous sync. Omitted or `0` = off. |
| `schedule.dailyTimes` | Fixed times, `HH:mm`, local time. A time missed while the Mac was asleep is run on wake. |
| `schedule.dailyTimesEnabled` | `false` turns fixed times off while keeping the list. Omitted = on. |
| `schedule.syncOnLaunch` | Sync when the app starts. |
| `folders[].localPath` | Local folder (`~` allowed). |
| `folders[].s3Prefix` | Prefix ("folder") in the bucket. Default: the local folder's name. `""` uploads to the bucket root. |
| `folders[].exclude` | Patterns to skip, see [Exclusions](#exclusions). `.DS_Store`, `._*` and similar macOS files are always skipped. |

## Exclusions

Each `exclude` pattern is read like a line of a `.gitignore` file placed at the root of the synced folder:

| Pattern | Effect |
| --- | --- |
| `*.tmp` | No `/`: any file or folder with that name, at any depth. |
| `node_modules` | That folder (and everything in it) wherever it is. |
| `docs/*.pdf` | Contains a `/`: anchored at the root. Matches `docs/a.pdf`, not `docs/sub/a.pdf` (`*` does not cross `/`). |
| `/build` | Leading `/`: only `build` at the root. |
| `tmp/` | Trailing `/`: only folders named `tmp`, with their content. |
| `**/logs` | `logs` at any depth. |
| `cache/**` | Everything inside `cache` (but not `cache` itself). |
| `docs/**/*.pdf` | PDFs in `docs` and all its subfolders. |
| `!keep.log` | Re-include: the last matching pattern wins. |

- Blank lines and lines starting with `#` are ignored; use `\#` and `\!` for names starting with `#` or `!`.
- As with git, you cannot re-include a file whose parent folder is excluded: `["build/", "!build/keep.txt"]`
  still excludes `build/keep.txt`. Write `["build/*", "!build/keep.txt"]` instead.
- Matching is case-sensitive; accented names are compared after Unicode (NFC) normalization.
- An excluded file is never deleted from S3, even with `deleteRemote`.

## AWS credentials

Credentials are resolved in this order:

1. The profile `awsProfile` (or `default` when neither a profile nor an access key is configured):
   1. static keys in the profile (`aws_access_key_id` / `aws_secret_access_key`, optional `aws_session_token`);
   2. IAM Identity Center (SSO), handled natively (below);
   3. the profile's `credential_process` (not in the sandboxed build);
   4. otherwise `aws configure export-credentials --profile <profile>` through the AWS CLI v2, which covers
      assume-role and anything else the CLI supports (not in the sandboxed build).
2. If the profile is missing or fails, and `accessKeyId` is set: that access key, with its secret read from
   1. the macOS Keychain (generic password, service `SimpleSyncS3`, account = the access key ID);
   2. otherwise `secretAccessKey` in `config.json` (the log warns that it is stored in plain text).

The source used is written to the log at every sync (access key IDs are shown shortened, secrets never).
If nothing works, the menu lists why each source failed.

### Profile from `~/.aws` (recommended)

```ini
# ~/.aws/credentials
[backup]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

```json
{ "awsProfile": "backup", "region": "eu-west-3", "bucket": "my-backup-bucket", "folders": [...] }
```

### Access key + Keychain, no profile

```json
{ "accessKeyId": "AKIA...", "region": "eu-west-3", "bucket": "my-backup-bucket", "folders": [...] }
```

Then **Secret Key…** in the settings (or the menu item **Save AWS Secret Key…**) and paste the
secret. The app creates the Keychain item itself, so it can read it back without prompting. Keep `awsProfile`
as well if you want the profile to have priority and the key to act as a fallback.

You may also put `"secretAccessKey": "..."` directly in `config.json`. It works, but anyone who can read your
home folder can read it: prefer the Keychain.

### IAM Identity Center (SSO)

Both `~/.aws/config` formats are supported: `sso_session` + an `[sso-session …]` section (recommended, supports
token refresh) and the legacy format (`sso_start_url` / `sso_region` in the profile). The profile needs
`sso_account_id` and `sso_role_name`.

- The token is read from `~/.aws/sso/cache`, the same cache as the AWS CLI: an `aws sso login` done elsewhere
  works for Simple Sync S3 too, and vice versa.
- An expired token is refreshed automatically when a refresh token exists (`sso_session` format).
- Otherwise, use **Sign In to AWS…** in the menu: your browser opens the IAM Identity Center page with the
  code pre-filled (the code is also shown in the menu and the log). Approve it and the next sync proceeds.
  From the command line: `s5-sync --config … --login`.
- Role credentials stay in memory and are never written to disk.

## Minimal IAM policy

The app only calls `ListObjectsV2`, `PutObject` and, if `deleteRemote` is on, `DeleteObject`. A policy limited
to one bucket and one prefix (replace `my-backup-bucket` and `s5/`; use one `s3:prefix` / `Resource`
entry per synced folder prefix, or a common parent prefix):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::my-backup-bucket",
      "Condition": { "StringLike": { "s3:prefix": ["s5/*"] } }
    },
    {
      "Sid": "WriteBackupPrefix",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-backup-bucket/s5/*"
    }
  ]
}
```

Drop `s3:DeleteObject` if you never enable `deleteRemote`. With that policy, set each folder's `s3Prefix` under
the allowed prefix, e.g. `"s3Prefix": "s5/invoices"`.

Good practice for a backup bucket: enable **S3 Versioning** (an overwritten or deleted file can be recovered)
together with a lifecycle rule that expires old versions after some days, and keep **Block Public Access** on.

## How syncing works

- For each folder, the app lists local files and the S3 objects under the folder's prefix.
- A file is uploaded if it is missing from S3, if its size differs, or if its content changed. A local cache
  (`state.json`, size + modification date) avoids re-reading unchanged files; when in doubt the MD5 is compared
  with the S3 ETag. On a first run against a bucket that already holds the same files, identical files are not
  re-uploaded.
- Files are uploaded with the `STANDARD` storage class, over HTTPS.
- S3 objects are deleted only if `deleteRemote` is `true`, and never when the prefix is empty (whole bucket) or
  the local folder is empty or missing.
- Symbolic links are skipped; only regular files are uploaded.
- Log: `~/Library/Logs/SimpleSyncS3/sync.log` (menu **Open Log**).
- Config, cache and state live in `~/Library/Application Support/SimpleSyncS3/`.

## Costs and large folders

S3 is billed by AWS to you. Before pointing the app at a big folder:

- **Storage**: every synced byte is stored, at the `STANDARD` price of your region. With versioning on, old
  versions are billed too until a lifecycle rule removes them.
- **Requests**: each upload is a `PUT` request, and each sync lists the prefix (one `LIST` request per 1,000
  objects). A folder with hundreds of thousands of small files costs more in requests than in storage; consider
  excluding caches, `node_modules/`, `.git/`, build outputs and the like.
- **The first sync of a large folder can take hours** and uses your upload bandwidth. It can be interrupted:
  files already uploaded are not sent again. Later syncs only send what changed.
- Uploading to S3 is free; **downloading** (restoring) is billed as data transfer out.
- To lower storage costs you can add an S3 lifecycle rule that moves objects to a cheaper class (e.g.
  Glacier Instant Retrieval); the app keeps comparing by size and ETag, which does not change with the class.
- Set a budget alert in AWS Billing if you are unsure.

## Sandboxed build

```bash
./scripts/install.sh --sandbox     # or ./scripts/build-app.sh --sandbox
```

The sandboxed build is signed with [`Resources/SimpleSyncS3.entitlements`](Resources/SimpleSyncS3.entitlements):
outbound network, user-selected files (read/write) and security-scoped bookmarks. Same code; the app detects
the sandbox at launch (`(sandbox)` in the log). Differences:

- **Folder access.** A sandboxed app only reads what you showed it. The menu shows
  **Folders needing access: N** and **Grant Access…**: a panel
  opens on `~/.aws` (if a profile is configured) then on each synced folder; click **Allow**. Only once:
  grants are kept as bookmarks. Choosing a parent folder covers its subfolders. A folder added with **+** in the
  settings is granted directly. A folder without access is skipped (nothing is deleted from S3).
- `~/.aws` is read for profiles and written for the SSO cache (shared with the AWS CLI).
- Static-key and SSO profiles work. `credential_process` and the AWS CLI (hence assume-role) are not available:
  the app says so and falls back to `accessKeyId` + Keychain if configured.
- App files live in `~/Library/Containers/com.jerry42.SimpleSyncS3/Data/` (config, cache, `bookmarks.json`,
  logs). The non-sandboxed configuration is not copied over; copy it with
  `cp ~/Library/Application\ Support/SimpleSyncS3/config.json ~/Library/Containers/com.jerry42.SimpleSyncS3/Data/Library/Application\ Support/SimpleSyncS3/`
- In `config.json`, `~` still means your real home folder, not the container.

## Command-line sync

The `s5-sync` target runs a single sync with the same engine, without the menu bar app, from a
configuration file anywhere. Handy for testing a configuration or for cron / launchd jobs.

```bash
swift build -c release
.build/release/s5-sync --config ~/backup-test/config.json [--state ~/backup-test/state.json] [--login]
```

- `--config`: same format as `config.json` (`schedule` and `launchAtLogin` are ignored).
- `--state`: sync cache; default `state.json` next to the config file.
- `--login`: start the IAM Identity Center login for the profile.
- Exit code: `0` success, `1` the sync hit an error, `2` invalid configuration.

It never touches `~/Library/Application Support/SimpleSyncS3`. The log goes to the terminal and to
`~/Library/Logs/SimpleSyncS3/sync.log`.

## Languages

The app is available in **English** and **French**. It follows the macOS language: French when French comes
first in System Settings → General → Language & Region, English otherwise (including for languages the app
does not support). To pick a language for this app only, add it under **Applications** in the same pane
(Language & Region → Applications → +), then relaunch the app.

What is translated: menus, the settings window, alerts, status and error messages, the folder access prompts
and the built-in help page. Log messages are written in English, with error details in the interface language.
The `s5-sync` command-line tool prints English.

Translations live in `Resources/<language>.lproj/` and are copied into the app by `scripts/build-app.sh`:

- `Localizable.strings`: the keys are the English texts used in the code (SwiftUI `Text("…")` literals and
  `L10n.tr("…")` in `S5Core`), mapped to the translation. Keep the `%@` / `%lld` placeholders in the same order.
- `InfoPlist.strings`: the folder access prompts from `Info.plist`.
- `Help.html`: the help page opened by the **Help** menu item.

To add a language, create `Resources/<code>.lproj/` with these three files (start from `fr.lproj`) and add the
code to `CFBundleLocalizations` in `Resources/Info.plist`. `swift run` has no app bundle, so it always shows
English; build the app with `./scripts/build-app.sh` to see a translation.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| macOS asks for access to Documents (or Desktop, Downloads, an external drive) after every update | The app is signed ad hoc. Once: `./scripts/create-signing-cert.sh`, then `./scripts/install.sh`. Grant access one last time; it is kept across updates afterwards. |
| The sync seems stuck at the start | A macOS permission prompt is probably waiting, sometimes behind other windows. Answer it. If you clicked "Don't Allow", re-enable Simple Sync S3 in System Settings → Privacy & Security → Files and Folders (or Full Disk Access). |
| macOS asks for Keychain access | Click "Always Allow". If it comes back after every update, see the signing certificate above, or store the secret again from the menu. |
| "credentials" / "profile" error in the menu | The menu lists each source tried and why it failed. Check the profile name, `aws sts get-caller-identity --profile <name>`, and that the region matches the bucket. |
| SSO token expired | Menu → **Sign In to AWS…**, or `aws sso login --profile <name>`. |
| `AccessDenied` (403) | The IAM policy does not cover this bucket or prefix, or `s3:DeleteObject` is missing with `deleteRemote`. Check the S3 key shown in the log against your policy. |
| `PermanentRedirect` / region error | `region` does not match the bucket's region. |
| A file is never uploaded | It may match an exclusion (built-in ones include `.DS_Store` and `._*`) or be a symbolic link. Files over 5 GB are reported as errors in the log (see Limitations). |
| Changes to `config.json` are ignored | Use **Reload Configuration** (⌘R). If the file is invalid JSON the settings window shows the error. |
| Where are the logs? | `~/Library/Logs/SimpleSyncS3/sync.log` (sandboxed build: inside the container, see above). |

## Development

```bash
swift run                # run the menu bar app from the terminal (English only), logs in the terminal
swift test               # unit tests, never call AWS
open Package.swift       # or open the package in Xcode
```

- `Sources/S5Core`: library with all the logic (config, scheduler, credentials, SigV4, S3 client, SSO,
  exclusions, sync engine).
- `Sources/SimpleSyncS3`: the SwiftUI menu bar app and settings window.
- `Sources/s5-sync`: the command-line target.
- `Resources`: `Info.plist`, entitlements, and one `<language>.lproj` folder per language (see [Languages](#languages)).
- `.github/workflows`: CI (build and tests on every push and pull request) and the release workflow.
- `Tests/S5Tests`: SigV4 is checked against the examples from the AWS documentation and values computed
  by botocore; SSO uses a fake HTTP transport.

To publish a release: add a section for the new version to [`CHANGELOG.md`](CHANGELOG.md), then push a tag
`vX.Y.Z` (or run the **Release** workflow from the Actions tab with the version). The workflow runs the tests,
builds the universal app and `s5-sync`, and publishes them with the changelog section as release notes.

## Limitations

- Files larger than 5 GB are skipped (no multipart upload yet).
- One-way only: nothing is restored from S3. Use the AWS console, the AWS CLI (`aws s3 sync s3://bucket/prefix ./restore`)
  or any S3 client to get files back.
- Not notarized by Apple: see [Download a release](#download-a-release) for how to open it, or build it yourself.

## License

Copyright (C) 2026 Jeremy Sculfort

Simple Sync S3 is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License v3.0](LICENSE) as published by the Free Software Foundation.
Anyone who distributes a modified version, free or paid, must publish its full source code under the same license.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the license for details.
