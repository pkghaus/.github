# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: open the **Security** tab on the
affected repository and choose **Report a vulnerability**. The report stays
private to you and us, and it keeps the discussion attached to the code it
concerns.

If you would rather use email, write to **security@pkg.haus**. That address is
also published at
[apt.pkg.haus/.well-known/security.txt](https://apt.pkg.haus/.well-known/security.txt)
per RFC 9116.

Either way, please include enough to reproduce, and give us a chance to ship a
fix before disclosing publicly.

Please do not open a public issue. GitHub keeps a public edit history of issue
and comment bodies, so a leak cannot be taken back by editing.

## What is in scope

- The archive at **apt.pkg.haus**: the signed indices, the pool, the keyring
  package, and the edge that serves them.
- The **packaging** in [packages](https://github.com/pkghaus/packages):
  `debian/rules`, build-time dependency handling, anything that affects what
  lands in a binary package.
- The **build pipeline**: `action-debian-build`, the builder images, the
  ingest that publishes to the archive.
- **pkg.haus** and its setup instructions. Bad instructions are a real
  vulnerability here: they are what a user pastes into a root shell.

Vulnerabilities in the upstream software we package are the upstream
project's to fix. Tell us anyway if a released package is affected, so the
version can be moved along.

## Verifying what you install

Every release index is signed. The archive key is:

```
pub   ed25519 2026-08-13 [C] [expires: 2031-08-12]
      79C1 BBCB E46F A8B9 EBAC  C930 20F9 23EB 99EC 1720
uid   pkg.haus archive signing key <archive@pkg.haus>
sub   ed25519 2026-08-13 [S] [expires: 2028-08-12]
      DD34 C42E 776B 591F BFEB  72A1 62B6 7F3E A1FA 6DEC
```

The primary key certifies and never signs the archive; the subkey signs
every `InRelease`. Check what you have against the fingerprints above:

```sh
gpg --show-keys /usr/share/keyrings/pkghaus-archive-keyring.gpg
```

Installing the `pkghaus-archive-keyring` package puts the key under dpkg's
management, so rotations arrive through `apt upgrade` rather than by
re-running a setup command.

## What the signature does and does not tell you

A valid signature says the index came from us unmodified. It does not say the
upstream release was benign, and it does not make a package reviewed
software. Packages are built from source at upstream's own release tags, in
the open, with provenance and SBOMs attached to the builder images. That is a
supply-chain story, not an audit.
