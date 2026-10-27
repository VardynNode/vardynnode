# Checking a download

Every VardynNode package is published with a SHA-256 checksum and a minisign signature. Check both before you run anything.

- Package: https://vardynnode.com/files/VardynNode-Setup.zip
- Checksum: https://vardynnode.com/files/VardynNode-Setup.zip.sha256
- Signature: https://vardynnode.com/files/VardynNode-Setup.zip.minisig
- The checksum of the current release is also on the [Download page](https://vardynnode.com/download) and in the notes of each release in [`releases/`](releases) and on the [Releases page](https://github.com/VardynNode/vardynnode/releases).

## The public signing key (minisign)

```
RWRHtMOGHSz0oywqtMdW5cQkw2UE1llujBPPnUFkW1RGaz9qRFZHZKSj
```

This is the same key that is pinned inside the one-line installer and the updater (see `installer/deploy/get-apexquant.sh` and `installer/deploy/aq-update.sh`). It is the public key only.

## Check it with the script

```
./verify.sh                       # downloads the package and checks it
./verify.sh VardynNode-Setup.zip  # checks a file you already have
```

## Or by hand

```
curl -fsSLO https://vardynnode.com/files/VardynNode-Setup.zip
curl -fsSLO https://vardynnode.com/files/VardynNode-Setup.zip.minisig
curl -fsSLO https://vardynnode.com/files/VardynNode-Setup.zip.sha256
sha256sum VardynNode-Setup.zip              # must equal the contents of VardynNode-Setup.zip.sha256
minisign -Vm VardynNode-Setup.zip -P RWRHtMOGHSz0oywqtMdW5cQkw2UE1llujBPPnUFkW1RGaz9qRFZHZKSj -x VardynNode-Setup.zip.minisig
```

`minisign` prints `Signature and comment signature verified` when the file is the one we signed. If either check fails, do not use the file and write to [hello@vardynnode.com](mailto:hello@vardynnode.com).
