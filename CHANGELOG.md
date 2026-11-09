# Changelog

All notable changes to Simple Sync S3 are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- `RequestTimeTooSkewed` (S3 HTTP 403) when the Mac's clock is more than 15 minutes off, for example just
  after waking from sleep: the app now reads S3's time from the error, re-signs the request with it and
  retries once, then keeps that correction for the rest of the sync. The measured gap is written to the log.

## [1.0.1] - 2026-11-09

### Added

- App icon (cloud with sync arrows), shown in Finder, Launchpad and the Settings window. Source SVG in
  `Resources/AppIcon/`, regenerate the `.icns` with `scripts/make-icon.py`.

## [1.0.0] - 2026-11-09

First public release.

### Features

- macOS menu bar app (macOS 13 Ventura or later, Apple silicon and Intel) that backs up chosen folders to
  an Amazon S3 bucket, one way (Mac → S3).
- Scheduling: every N minutes, at fixed times of day (missed times are caught up after sleep), at launch,
  or on demand with **Sync Now**. Each can be turned off.
- Credentials from your existing AWS setup: named profiles in `~/.aws` (static keys, IAM Identity Center / SSO
  with built-in sign-in, `credential_process`, assume-role through the AWS CLI), or an access key whose secret
  is stored in the macOS Keychain.
- Safe by default: local deletions are mirrored to S3 only if you turn it on, and never for a folder synced to
  the bucket root or a local folder that is empty or missing.
- Per-folder `.gitignore`-style exclusions.
- Settings window (AWS account, schedule, folders, JSON mode) and a progress indicator in the menu.
- Unchanged files are detected with a local cache and the S3 ETag, so they are never uploaded twice.
- `s5-sync` command-line tool running the same engine, for testing a configuration or cron / launchd jobs.
- Optional App Sandbox build.
- English and French interface and built-in help page.
- No third-party dependencies: the S3 client (SigV4) and the SSO login are written in Swift on top of
  `URLSession` and CryptoKit.

### Downloads

- `SimpleSyncS3-1.0.0-macOS.zip`: the app (universal binary). It is not notarized by Apple: see
  [Download a release](https://github.com/jerry42/simple-sync-s3#download-a-release) in the README for how to
  open it the first time.
- `s5-sync-1.0.0-macOS.zip`: the command-line tool (universal binary).
- `SHA256SUMS.txt`: checksums of both files.

### Known limitations

- Files larger than 5 GB are skipped (no multipart upload yet).
- One-way only: nothing is restored from S3.

[1.0.1]: https://github.com/jerry42/simple-sync-s3/releases/tag/v1.0.1
[1.0.0]: https://github.com/jerry42/simple-sync-s3/releases/tag/v1.0.0
