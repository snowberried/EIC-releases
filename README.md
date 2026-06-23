# EIC-releases

EIC desktop app updater distribution repository.

## Updater endpoint

The app checks this GitHub Releases asset:

```text
https://github.com/snowberried/EIC-releases/releases/latest/download/latest.json
```

Do not use the git clone URL as the in-app updater endpoint.

## Release workflow

Use **Actions -> Publish EIC Release -> Run workflow**.

- `source_ref`: branch, tag, or commit in `snowberried/EIC` to build.
- `prerelease`: keep off for normal releases. The EIC app ignores prereleases by default.

The workflow builds the Windows Tauri app and uploads:

- Windows NSIS setup exe
- Tauri updater bundle: `*.nsis.zip`
- Signature file: `*.nsis.zip.sig`
- Static updater manifest: `latest.json`

## Required repository secrets

- `SOURCE_REPO_TOKEN`: GitHub token that can read the private `snowberried/EIC` source repository.
- `TAURI_SIGNING_PRIVATE_KEY`: Tauri updater signing private key.
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: Tauri updater signing key password.

Never commit the private signing key to this repository.
