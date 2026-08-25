<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="pkghaus-dark.svg">
    <img src="pkghaus.svg" height="56" alt="pkg.haus - a taped parcel with a haus stenciled on its face">
  </picture>
  pkg.haus
</h1>

What Debian doesn't ship, packaged as if it did. Current upstream releases,
built from source for Debian stable, testing and unstable on amd64 and
arm64, served from a signed APT archive.

## Use the archive

Follow the installation instructions on [pkg.haus](https://pkg.haus), then run:

```sh
sudo apt install <package>
```

The package pool is browsable at [apt.pkg.haus](https://apt.pkg.haus).
Added, updated and retired packages are listed at
[apt.pkg.haus/news](https://apt.pkg.haus/news/), with an
[RSS feed](https://apt.pkg.haus/news/feed.xml). Download counts, measured at
the edge, are published at [apt.pkg.haus/stats](https://apt.pkg.haus/stats).

## How it works

- [apt](https://github.com/pkghaus/apt): the archive. A packaging
  repository's validated tag triggers the ingest, which builds the release
  from source and publishes only what the archive lacks.
- [action-debian-build](https://github.com/pkghaus/action-debian-build):
  the build action and per-suite builder images, native amd64 and arm64,
  with provenance and SBOMs. Also on the
  [GitHub Marketplace](https://github.com/marketplace/actions/action-debian-build).
- [archive-keyring](https://github.com/pkghaus/archive-keyring): the signing
  key as a package, so key rotations arrive through `apt upgrade`. Its
  fingerprint is in [SECURITY.md](https://github.com/pkghaus/.github/blob/master/SECURITY.md).

## Buy us a coffee?

If you feel like buying us a coffee (or a beer?), donations are welcome:

```
BTC : bc1qq04jnuqqavpccfptmddqjkg7cuspy3new4sxq9
DOGE: DRBkryyau5CMxpBzVmrBAjK6dVdMZSBsuS
ETH : 0x2238A11856428b72E80D70Be8666729497059d95
LTC : MQwXsBrArLRHQzwQZAjJPNrxGS1uNDDKX6
```
