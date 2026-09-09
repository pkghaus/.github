# Contributing

## Requesting a package

Open an issue on [apt](https://github.com/pkghaus/apt/issues). Before you do,
check the three things that decide it, because a request that fails any of
them will be declined:

1. **Debian does not already ship it**, in trixie or in sid. If it is in
   Debian, use Debian's. Packages here are retired when Debian catches up.
2. **Upstream does not publish a working `.deb`** you could install directly.
3. **No maintained third-party apt repository already carries it.**

Say which upstream project, and what you checked. If it clears those, the
remaining question is whether it can be built from source at an upstream
release tag on amd64 and arm64, and whether its function can be proven
automatically rather than by someone squinting at `--version`.

## Reporting a broken package

Open an issue on [packages](https://github.com/pkghaus/packages), naming the
package, unless the archive itself is at fault. What helps:

```sh
apt policy <package>          # which version, from which suite
dpkg -l <package>             # what is actually installed
cat /etc/os-release           # which Debian
dpkg --print-architecture     # amd64 or arm64
```

If the failure is an `apt update` error rather than the software
misbehaving, that is an archive problem and belongs on `apt`.

## Security

Do not open an issue. See [SECURITY.md](SECURITY.md); the address is
security@pkg.haus.

## Changing packaging

Pull requests are welcome on any package's `debian/` directory in
[packages](https://github.com/pkghaus/packages). Two things to know:

- **Version bumps land automatically** every six hours, already built and
  DEP-8 tested across every suite before they land, so a change that only
  edits `package.conf` has usually happened already. Nothing approves them and
  there is no pull request to review: a bump that verifies commits straight to
  `master`, and landing is releasing -- the commit tags the package and tells
  the archive to ingest. A bump that needs packaging changes fails
  verification and does not land, and those are the ones worth a
  contribution. The `Upstream release drift` issue on `packages` lists them.
- **Every published version is immutable.** Once a version is in the pool it
  is never rebuilt with different bytes; a fix ships as a new Debian
  revision.

Commits are signed. If yours are not, they can still be merged, but the
merge commit is what carries the signature.
