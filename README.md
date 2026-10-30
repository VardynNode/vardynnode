# VardynNode

VardynNode is trading software for Binance that you install and run on your own server. You choose one strategy (DCA, Directional or Grid) and it trades on your own Binance account.

This repository publishes what runs on your server when VardynNode is installed and updated, and how to check a download. It is published for transparency; it is not open source (see [LICENSE](LICENSE)).

## Why it can be trusted

Every point links to the page on vardynnode.com that states it.

- **It never needs withdrawal permission.** VardynNode does not need it and refuses to start when Withdrawals is enabled on the API key: [Guide, step 4](https://vardynnode.com/guide#step4) and the [FAQ](https://vardynnode.com/faq).
- **Your keys stay on your server.** VardynNode does not hold your funds or your API keys, and they never reach us: [About](https://vardynnode.com/about).
- **Every download has a checksum and a signature.** The checksum is on the [Download page](https://vardynnode.com/download); [RELEASES.md](RELEASES.md) and [verify.sh](verify.sh) (run it with `bash verify.sh`) show how to check both.
- **Our own live account is shown as it is,** delayed 15 minutes and in percentages: [Live](https://vardynnode.com/live).
- **Support and security.** Write to [hello@vardynnode.com](mailto:hello@vardynnode.com) or use the [Contact page](https://vardynnode.com/contact). To report a security issue, see [SECURITY.md](SECURITY.md).

## What is here

| Path | What it is |
|---|---|
| `installer/deploy/get-vardynnode.sh` | the one-line installer, served at get.vardynnode.com: downloads the package, verifies its signature with a pinned key, unpacks it and runs the package's install step |
| `installer/deploy/vn-update.sh` | the updater, served at get.vardynnode.com/update: verifies its own signature, then the package's checksum and signature, before it replaces anything |
| `installer/update_license.sh` | enter or change the license key |
| `installer/update_keys.sh` | change the Binance API keys |
| `installer/update_telegram.sh` | change the Telegram settings |
| `installer/update_env.sh` | change other settings in the .env file |
| `installer/licence_key.sh` | the one place that knows the two license-key forms (used by update_license.sh and the installer) |
| `installer/deploy/layout.sh` | the install layout (folder, service and data names), sourced by the scripts |
| `installer/deploy/layout_paths.py` | the same layout for Python helpers |
| `installer/deploy/migrate-layout.sh` | moves an older install to the current folder names |
| `installer/deploy/migrate-common.sh` | shared parts of the three migration scripts |
| `installer/deploy/migrate-db-name.sh` | renames the data file to the current name |
| `installer/deploy/update-cloudflare-ips.sh` | refreshes the list of Cloudflare address ranges for servers behind Cloudflare |
| `installer/deploy/cloudflare-ips.service` | systemd unit that runs the script above |
| `installer/deploy/cloudflare-ips.timer` | systemd timer for the unit above |
| `installer/deploy/cloudflare-ips.conf` | the seed list of Cloudflare address ranges |
| `installer/deploy/vardynnode.service` | the systemd unit template for the bot |
| [`installer/SHA256SUMS`](installer/SHA256SUMS) | the SHA-256 checksum of each file above, as shipped |
| [`RELEASES.md`](RELEASES.md), [`verify.sh`](verify.sh) | how to check a download's checksum and signature, with the public signing key |
| [`releases/`](releases) | what changed in each release, with its checksum |
| [`SECURITY.md`](SECURITY.md) | how to report a security issue |

The scripts are shown exactly as they ship in the package (shell scripts with Unix line endings, the other files byte for byte). Compare any of them with the copy on your own server using the checksums in `installer/SHA256SUMS`.

Some installer helper scripts are not published here; the full set ships inside VardynNode-Setup.zip, which you can verify with its .sha256 and .minisig.

## Install

Follow the [Quick Install](https://vardynnode.com/quickstart) page or the full [Guide](https://vardynnode.com/guide). The one-line installer is run as root on a clean Ubuntu 24.04 server; the package's install step is inside the signed download; its source follows. Read the one-line installer first in [`installer/deploy/get-vardynnode.sh`](installer/deploy/get-vardynnode.sh).

## Repository

[VardynNode/vardynnode](https://github.com/VardynNode/vardynnode) - [Releases](https://github.com/VardynNode/vardynnode/releases) - clone: `git clone https://github.com/VardynNode/vardynnode.git`
