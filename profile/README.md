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

## How it works

- [apt](https://github.com/pkghaus/apt): the archive. A packaging
  repository's validated tag triggers the ingest, which builds the release
  from source and publishes only what the archive lacks.
- [action-debian-build](https://github.com/pkghaus/action-debian-build):
  the build action and per-suite builder images, native amd64 and arm64,
  with provenance and SBOMs. Also on the
  [GitHub Marketplace](https://github.com/marketplace/actions/action-debian-build).
