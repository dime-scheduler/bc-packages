# Dime.Scheduler Business Central packages

Distribution point for the [Dime.Scheduler Business Central connector](https://github.com/dime-scheduler/bc-connector): every connector version is a [release](../../releases) here carrying one NuGet package per supported Business Central major, and those releases are served as a NuGet feed on GitHub Pages.

| | |
|---|---|
| Feed URL | `https://dime-scheduler.github.io/bc-packages` |
| Package ids | `DimeSoftware.DimeScheduler.BC{major}.f15bbe6d-c2a3-4828-aa98-5a77cff4cd41` |
| Versions | the connector's own app version, e.g. `3.1.0.0` |
| Also on | [nuget.org](https://www.nuget.org/packages?q=DimeSoftware.DimeScheduler) (same packages) |

## Using the feed

### AL extension in VS Code

Add to `.vscode/settings.json` of the app that depends on the connector, then run `AL: Download symbols from global sources`:

```json
{
    "al.nugetFeeds": [
        "https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/MSSymbolsV2",
        "https://dime-scheduler.github.io/bc-packages"
    ],
    "al.useOnlyCustomFeeds": true
}
```

`al.useOnlyCustomFeeds` matters: the extension searches Microsoft's built-in AppSource symbols feed first and stops at its first hit, and that feed resolves the connector to a stale package id. Listing Microsoft's MSSymbolsV2 feed keeps the Microsoft symbols working.

The extension takes the first package whose id contains the app id, regardless of the project's BC version, so the feed always lists the newest major first. That is the build you get in VS Code.

### BcContainerHelper and AL-Go

Both read the same feed and pick the major matching the target platform through each package's `Microsoft.Application` version range:

```powershell
Download-BcNuGetPackageToFolder -nuGetServerUrl https://dime-scheduler.github.io/bc-packages/nuget/v3/index.json -packageName f15bbe6d-c2a3-4828-aa98-5a77cff4cd41 -folder .\apps
```

nuget.org works for these tools as well; the feed here is a second source.

## How it is published

1. The bc-connector publish workflow builds every major on a GitHub release and creates a release here with the same tag (`v3.1.0.0`) and the `.nupkg` files as assets. It authenticates with the `BC_PACKAGES_TOKEN` secret, a fine-grained token with *Contents: write* on this repository.
2. The release triggers [feed.yml](.github/workflows/feed.yml), which runs [Build-Feed.ps1](scripts/Build-Feed.ps1): it downloads every release's packages and writes the feed as plain files, then deploys them to GitHub Pages.

Releases can also be created by hand with the same tag format; the feed rebuilds on any release change. Nothing is committed to this repository per version.

### Custom domain

1. Add a DNS `CNAME` record for the chosen host pointing at `dime-scheduler.github.io`.
2. Set the host under *Settings > Pages > Custom domain* and enforce HTTPS.
3. Set the repository variable `FEED_BASE_URL` to `https://<host>` and re-run the Feed workflow, so the URLs inside the feed match.

## Why not just nuget.org

The AL extension hardcodes the Azure DevOps Artifacts URL layout (`{feed}/nuget/v3/index.json` and `{feed}/nuget/v3/flat2/...`) and cannot read nuget.org. Public Azure DevOps projects are retired. Microsoft's own AppSource symbols feed carries two package ids for the connector since the publisher was renamed in 2025, and the extension picks the stale one. A static feed in the expected shape sidesteps all three.
