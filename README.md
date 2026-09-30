# Scripts for building opnsense (https://opnsense.org) focused on ARM64 targets

These files aim for the FriendlyELEC **NanoPi R5C** (RK3568B2, 2x RTL8125B 2.5GbE). Can be used for other ARM64 systems, and also for building images for AMD64 if desired as well. Legacy conf files for NanoPi R5S and Orange Pi 5 Plus are kept in `arm64-opnsense-build/opnsense-confs/` but are no longer wired into the scripts by default.

Based on OPNsense 26.7 "Xenial Xenops" (FreeBSD 15.1). The default build is the latest version validated from the original repository, **26.7.4**. R5C images retain the original repository's `realtek-re-kmod198` driver: physical testing showed that the newer 1102.01 module recognizes both RTL8125 PCI IDs but rejects their chip revision during attach as an unknown device.

## Boot / storage notes for the R5C

- There is no `sysutils/u-boot-nanopi-r5c` port in the FreeBSD ports tree (only r5s), so `1.1-fetch_update.sh` creates a local slave port of `sysutils/u-boot-master` (see `arm64-opnsense-build/u-boot-nanopi-r5c/`) and builds it from the ports tree.
- There is no prebuilt EDK2/UEFI image for the R5C (quartz64_uefi does not ship one), so the images boot via U-Boot.
- The output is a whole-disk image containing the R5C U-Boot boot blobs and can be written to either microSD or the onboard 32 GB eMMC. FriendlyELEC documents both SD boot and several eMMC installation methods. Never assume a device name such as `/dev/mmcsd1`; identify the source and target on the actual board before writing.
- The active U-Boot fragment is intentionally limited to `mmc1 mmc0`: microSD and eMMC. NVMe, USB, PXE, and DHCP are not production boot targets while the R5C port is being proven.
- OPNsense/FreeBSD 15.1 includes the NanoPi R5S DTB but does not list the R5C DTB in its Rockchip DTB module. Stage 1.1 installs the upstream R5C description as a packaged fallback, keeps the two PCIe controllers for the RTL8125B NICs enabled, disables only the optional M.2 lane, and registers the DTB for the kernel build.
- The active boot path mirrors the working R5S U-Boot design: U-Boot supplies its R5C DTB through EFI and `loader.efi` automatically discovers the UFS partition containing `/boot/kernel`. Do not set `rootdev=ufs:/dev/ufs/...` in `/efi/freebsd/loader.env`; `rootdev` uses loader device syntax such as `disk0s1a`, while `ufs:/dev/ufs/...` is kernel mount-from syntax. The normal `/etc/fstab` label selects the root filesystem after the kernel starts.
- Future NVMe work is preserved but inactive in `u-boot-nanopi-r5c/files/nvme_fragment` and the `pcie2x1` marker in `freebsd-r5c/rk3568-nanopi-r5c.dts`. Both sides must be changed together after SD/eMMC boot is stable.

### Diagnostic image without UART

Pass `--diagnostic` to build `R5C_DIAG`. It uses the same SD/eMMC disk layout but U-Boot first:

1. Turns on the red power and green LAN LEDs.
2. Writes `R5CUBOOT.OK` after U-Boot can write to the FAT partition.
3. Scans only SD/eMMC and writes `R5CSCAN.OK` when that scan completes.
4. Selects the first valid flow and writes `R5CEFI.OK` immediately before launching it.
5. If no flow is valid or EFI returns, writes `R5CBOOT.FAIL`, turns on the green WAN LED for ten seconds, and resets.
6. At the first executable line of OPNsense's real `/usr/local/etc/rc`, writes `R5CINIT.OK` and `R5CINIT.TXT`.
7. After OPNsense inspects `/etc/fstab`, writes `R5CFSTB.OK` and `R5CFSTB.TXT`.
8. After filesystem preparation and PHP setup, writes `R5CPHP.OK` and `R5CPHP.TXT`.
9. After the PHP-based `rc.bootup` completes successfully, writes `R5CBOOT.OK` and `R5CBOOT.TXT`.
10. After normal startup hooks, writes `R5CRC.OK` and `R5CRC.TXT`.
11. Starts a bounded 30-minute live network recorder. While it is active the FAT partition contains `R5CNET.RUN`; on completion that becomes `R5CNET.OK`. Its `R5CNET.TXT` records the negotiated media, byte/error/drop counters, PCIe capabilities, Realtek sysctls, interrupt state, CPU frequency/load, and available thermal readings about every ten seconds.

Each OPNsense-stage `.TXT` snapshot includes mounts, GEOM labels, loader/kernel environment, interfaces, PCI devices, live OFW PCIe `ranges`, and `dmesg`. For this test, use a microSD card. No Ethernet link is expected until FreeBSD initializes the RTL8125B NICs; U-Boot networking is deliberately skipped because its DHCP retry prevented EFI from being attempted during the first board test. The accumulated files on `MSDOSBOOT` show the last completed stage without needing UART. Run any throughput test during the first 30 minutes after boot, shut OPNsense down normally, then return `R5CNET.TXT` with the other diagnostic files. To start another 30-minute capture without rebooting, run `daemon -f /usr/local/sbin/r5c-diag-netlog` as root over SSH.

The R5C HDMI connector is not a usable console with this mainline firmware stack. U-Boot 2026.07 builds the R5C with `CONFIG_VIDEO` disabled, and its Rockchip video driver supports RK3288/RK3399 rather than the RK3568 VOP2 display controller. The resulting EFI interface reports a `1x1` framebuffer (`efi_max_resolution="1x1"`), so FreeBSD's EFI console has nowhere to render. FreeBSD 15.1 also has the RK3568 display bindings but no RK3568 VOP2 console driver to initialize HDMI later. Enabling USB keyboard support alone cannot provide visible output. HDMI would require a separate R5C port of FriendlyELEC's vendor U-Boot DRM implementation or R5C-specific EDK2 firmware; it is intentionally not mixed into the currently proven SD/eMMC boot chain.

## How-to use

### Complete disposable UTM build on an Apple-silicon Mac

This plan installs build dependencies only inside a temporary FreeBSD VM. It does not use Homebrew, MacPorts, or install anything from the shell on macOS. The Mac needs UTM and Git already available. At the end, the repository contains the compressed R5C image and the UTM VM can be deleted.

The R5C build produces a raw disk image (`.img`), not an installer ISO. The launcher streams it through `xz` into a release-friendly `.img.xz` on the Mac and can optionally create the `.img.gz` expected by FriendlyWrt's eMMC Tools.

#### 1. Download the FreeBSD installer

Download the official [FreeBSD 15.1-RELEASE ARM64 disc1 ISO](https://download.freebsd.org/releases/arm64/aarch64/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-arm64-aarch64-disc1.iso). The [SHA-256 checksum file](https://download.freebsd.org/releases/arm64/aarch64/ISO-IMAGES/15.1/CHECKSUM.SHA256-FreeBSD-15.1-RELEASE-arm64-aarch64) is in the same directory.

#### 2. Create the UTM VM

In UTM:

1. Click **+** and choose **Virtualize**, then **Other**.
2. Select the downloaded ARM64 `disc1.iso` as the boot ISO and keep UEFI enabled.
3. Name the VM exactly `FreeBSD`. A different name works, but it must later be passed with `--vm`.
4. Assign about 8 CPU cores, 16 GB RAM, and a 100 GB virtual disk. Do not assign more cores or memory than the Mac can comfortably spare.
5. Use UTM's default **Shared Network** adapter.
6. A shared host directory is not required. [UTM's documented QEMU directory-sharing methods](https://docs.getutm.app/guest-support/sharing/directory/) target Windows and Linux guests, so this workflow deliberately uses SSH for FreeBSD.
7. Save and start the VM.

Install FreeBSD using the text installer:

1. Choose **Install**, select the normal keymap, and set any hostname.
2. Use **Auto (UFS)** over the entire virtual disk. UFS is the simplest disposable build-host layout.
3. Set a temporary root password that you can enter from the Mac.
4. Enable `sshd` when the installer asks about services. Enabling time synchronization is also recommended.
5. Finish the installation, shut down or reboot, and eject/remove the installer ISO so the VM boots from its virtual disk.

The [official OPNsense build tooling](https://github.com/opnsense/tools#setting-up-a-build-system) calls for FreeBSD 15.1, at least 16 GB RAM, and at least 50 GB of disk. The larger virtual disk above leaves room for ports, distfiles, packages, the raw image, and temporary build objects.

#### 3. Prepare the temporary FreeBSD guest

UTM clipboard integration is not required. Log in as `root` in the UTM console and type these three short commands by hand. The environment setting on the first line also accepts the one-time `pkg` bootstrap prompt.

```sh
env ASSUME_ALWAYS_YES=yes pkg install -y git
git clone https://github.com/alexanderjlynn/opnsense-r5c r
sh r/init-freebsd.sh
```

The repository's [`init-freebsd.sh`](init-freebsd.sh) performs the longer setup: it validates FreeBSD 15.1/aarch64/root, enables temporary root/password SSH, validates the SSH configuration, attempts to install and start the optional QEMU guest agent, and prints the VM's IPv4 address. Guest-agent failure is only a warning because the printed address can be supplied directly to the Mac launcher. It is safe to run again if setup was interrupted. Everything it installs or changes remains inside the disposable VM. This first clone is only the small bootstrap copy; the Mac launcher transfers the checkout you actually launch it from into `/root/opnsense-r5c-build` before building.

If the initializer does not print an address, run `ifconfig vtnet0` in FreeBSD and note the `inet` address. Supply that address as the second argument in step 4; this does not require a working guest agent.

#### 4. Clone and run the complete build from macOS

From a directory where you want the repository and final image, this is the complete Mac one-liner:

```sh
git clone https://github.com/alexanderjlynn/opnsense-r5c.git && cd opnsense-r5c && ./build-r5c-utm.sh 26.7.4 192.168.65.3
```

If the repository is already cloned:

```sh
./build-r5c-utm.sh 26.7.4 192.168.65.3
```

The first argument is the complete OPNsense release and the second is the address printed inside the VM. Substitute your actual address. Supplying it bypasses guest-agent discovery entirely. The default release remains `26.7.4`, so `./build-r5c-utm.sh` can still attempt automatic discovery.

To select another full OPNsense tag and provide its guest address:

```sh
./build-r5c-utm.sh 26.7.5 192.168.65.3
```

Add `--keep-raw` when you also want the uncompressed `.img` needed by an SD writer or direct `dd`:

```sh
./build-r5c-utm.sh --keep-raw 26.7.4 192.168.65.3
```

For a one-shot build that also creates an uploadable FriendlyWrt eMMC image, use:

```sh
./build-r5c-utm.sh --emmc-image 26.7.4 192.168.65.3
```

`--keep-raw` and `--emmc-image` may be combined. The former is useful for `dd`; the latter avoids transferring the 4 GB raw file when the goal is the web flasher.

For the first corrected boot test, reuse the completed 26.7.4 build in the existing VM and build the diagnostic image:

```sh
./build-r5c-utm.sh --boot-only --diagnostic --keep-raw --emmc-image 26.7.4 192.168.65.3
```

`--boot-only` rebuilds the local R5C U-Boot port, R5C DTB/device-specific kernel set, signatures, and final image from an already completed build. It enables OPNsense's `BARE=1` image mode so ports, plugins, core, and package targets are not rebuilt. The upstream image target still revalidates its base and kernel prerequisites, so this can take a while even when compiler output was cached. Before signing and again after image assembly, the script extracts and decodes the packaged R5C DTB and refuses to continue unless both corrected 64-bit PCIe identity mappings are present. It exits with a full-build command if the required same-release sets are unavailable. Do not use it when changing OPNsense releases.

The launcher will:

1. Start the UTM VM named `FreeBSD`.
2. Use the supplied IPv4 address, or ask UTM's guest agent only when no address was supplied.
3. Wait for SSH and ask once for the temporary FreeBSD root password.
4. Keep SSH host keys and its multiplexed connection in a temporary directory, not in `~/.ssh/known_hosts`.
5. Copy this checkout into `/root/opnsense-r5c-build` in the VM.
6. Check FreeBSD 15.1, ARM64, root access, release tags, and free space.
7. Pin `tools`, `src`, `core`, `plugins`, and `ports` to the exact selected
   point-release tag and verify every commit before compiling.
8. Record those source commits with the generated sets. If a later run finds
   cached output with changed or unknown source provenance, discard only that
   generated output so it cannot be mislabeled as the selected release.
9. Run every script from `1.1` through `9`, stopping at the first error.
10. Build the kernel for the selected R5C device name and verify the corrected R5C DTB inside both its kernel set and the assembled raw image.
11. Keep the Mac awake for the potentially long build without changing a persistent power setting.
12. Save the complete console output in `build-artifacts/VERSION/build-VERSION.log`, including failed runs.
13. Stream-compress the completed image back into `build-artifacts/VERSION/` in this repository, optionally copying the raw image or creating a web-flasher `.img.gz`.

macOS may show a one-time security request allowing the terminal to control UTM. That operating-system permission cannot be auto-accepted. The only other expected interaction is entering the temporary VM root password once.

For a differently named VM, put the option before the release and address:

```sh
./build-r5c-utm.sh --vm "OPNsense Builder" 26.7.4 192.168.65.3
```

Run `./build-r5c-utm.sh --help` for the remaining overrides. The selected OPNsense release must use the FreeBSD version installed in the VM; OPNsense rejects an incompatible host ABI.

#### Reuse this VM after pushing repository changes

The three-command bootstrap cloned this repository as `/root/r`. To make the VM download a newly pushed revision and perform a fast same-release boot-chain rebuild, run this from a Mac terminal:

```sh
ssh -t root@192.168.65.3 'cd /root/r && git pull --ff-only && cd arm64-opnsense-build && sh rebuild-r5c-boot.sh --diagnostic 26.7.4'
```

Enter the temporary VM root password. This changes only the disposable guest. If `/root/r` was deleted, repeat the short `git clone ... r` bootstrap command in the guest.

When that SSH rebuild completes, retrieve the diagnostic image without installing anything on macOS:

```sh
mkdir -p build-artifacts/26.7.4
ssh root@192.168.65.3 'xz -T0 -c /usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_DIAG.img' > build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_DIAG.img.xz
scp root@192.168.65.3:/usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_DIAG.img.sig build-artifacts/26.7.4/
shasum -a 256 build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_DIAG.img.xz > build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_DIAG.img.xz.sha256
```

Those are separate commands intentionally: never mix build log output and a binary image in the same SSH stream. To retrieve the raw image for Etcher instead, replace the remote `xz -T0 -c` command with `cat` and name the local file `.img`.

The Mac launcher is usually simpler because it transfers the local checkout, runs the same rebuild, and retrieves the result in one command. After pushing and updating the Mac checkout:

```sh
git pull --ff-only
./build-r5c-utm.sh --boot-only --diagnostic --keep-raw 26.7.4 192.168.65.3
```

After the diagnostic image reaches FreeBSD successfully, create the normal SD/eMMC image from the same cached build:

```sh
./build-r5c-utm.sh --boot-only --keep-raw --emmc-image 26.7.4 192.168.65.3
```

For a new release or a guest without a completed build, omit `--boot-only` so every numbered build stage runs.

#### 5. Collect and publish the result

After a successful default build, the Mac will contain:

```text
build-artifacts/26.7.4/
├── build-26.7.4.log
├── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz
├── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.sha256
└── OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.sig
```

The SHA-256 file verifies the compressed release asset. The `.sig` file is the OPNsense signature for the raw image after decompression. The log is for diagnosis and normally does not need to be uploaded. With `--keep-raw`, the directory also contains the much larger `.img`. `build-artifacts/` is ignored by Git so these files cannot accidentally be committed to normal repository history.

With `--emmc-image`, it also contains `OPNsense-VERSION-arm-aarch64-R5C_UBOOT.img.gz` and its SHA-256 file. The `.img.gz` is for FriendlyWrt eMMC Tools; do not put the raw image in a ZIP archive.

Verify the transferred asset before deleting the VM:

```sh
(cd build-artifacts/26.7.4 && shasum -a 256 -c OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.sha256)
```

To publish it without installing another Mac tool:

1. Open the repository on GitHub and select **Releases** → **Draft a new release**.
2. Create or choose a tag such as `r5c-26.7.4`.
3. Drag the three files above into the release-assets box and publish the release.

[GitHub requires each release asset to be under 2 GiB](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas). The launcher warns if the compressed image exceeds that. If needed, split it with the built-in macOS `split` command and attach the parts:

```sh
split -b 1900m build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz.part-
```

#### 6. Delete the temporary VM

Confirm the files exist under `build-artifacts/VERSION/`, shut down FreeBSD with `shutdown -p now`, and delete the VM from UTM. You may also delete the downloaded FreeBSD installer ISO. The launcher removes its temporary control socket and SSH host-key file automatically, leaving only this repository and the build artifacts on macOS.

### Validated build

The complete disposable-UTM compile workflow was run successfully on 2026-09-26 for OPNsense **26.7.4** using FreeBSD 15.1/aarch64, 8 virtual CPUs, and 16 GB RAM. It completed the R5C image and OPNsense signature, transferred a 1.3 GB compressed image to macOS, and passed `shasum -a 256 -c` against the generated checksum file. That original artifact did **not** boot the R5C, so it is build validation only.

The corrected `R5C_DIAG` boot chain was rebuilt successfully on 2026-09-29 in that same FreeBSD 15.1/aarch64 VM. The MEM64 test produced a signed 4 GiB raw image, 1.5 GiB `.img.xz`, and 1.7 GiB `.img.gz`; both compressed files passed their generated SHA-256 checks and `gzip -t` accepted the `.gz`. Its log proves that the MEM64-patched `pci_dw.o` and R5C DTB were rebuilt and packaged, then explicitly installed both `realtek-re-kmod198-198.00.1501000` and `opnsense-26.7.4_2` before the image signature verified successfully. Physical testing reached the complete OPNsense rc sequence but exposed the additional stale PCI bus-address translation documented below.

The first identity-mapped-range follow-up was also physically tested, but its NICs still read `TXCFG=0xffffffff`. Inspection of the finished raw image found that its embedded DTB still had the stale `0x40000000` PCI bus ranges even though the corrected source DTB had compiled successfully. The rebuild wrapper had built an unqualified `ARM64` kernel set, while final assembly selected the device-named cached `R5C_DIAG` kernel set. The scripts now pass the selected device through the kernel stage and hard-fail unless the corrected DTB is present in both `kernel-26.7.4-aarch64-R5C_DIAG.txz` and the final raw image.

That corrected path was rebuilt in the FreeBSD VM and transferred to macOS on 2026-09-30. The build log records `DEVICE=R5C_DIAG`, creation and reuse of the matching device-named kernel set, successful DTB verification at both packaging boundaries, and a verified OPNsense image signature. Both compressed artifacts pass their SHA-256 manifests and `gzip -t` accepts the `.gz`. The new `.img.gz` SHA-256 is `9c36428faf78f6a0dd641259c180bcdff7cd939641b90eddf5b03ebce9ccc85f`. Physical testing on a NanoPi R5C succeeded: the LAN interface obtained a DHCP lease, the OPNsense web interface and console menu were reachable, and an Internet speed test completed successfully.

The first physical test created only `R5CUBOOT.OK`. The expanded-marker test then created `R5CUBOOT.OK`, `R5CSCAN.OK`, and `R5CEFI.OK`, but neither `R5CBOOT.FAIL` nor an OS-side marker. This proves the ROM, SPL, U-Boot, FAT access, bootflow scan, EFI selection, and transfer into `BOOTAA64.EFI`. Review of the matching FreeBSD 15.1 loader source found that the generated `loader.env` forced the kernel-style value `ufs:/dev/ufs/OPNsense_ARM` into the loader-only `rootdev` variable. FreeBSD deliberately trusts that value even when invalid and skips automatic disk discovery. After removing that override, the same three firmware markers were created but the LEDs turned off roughly 20 seconds after EFI handoff instead of remaining on, consistent with later-stage control taking over GPIO. Image inspection then showed that OPNsense replaces normal FreeBSD rc processing with an immediate `exec /usr/local/etc/rc`, so the earlier `/etc/rc.d` checkpoints could never report that progress. The next physical test created every checkpoint through `R5CRC.OK`, proving that FreeBSD mounted the SD root read/write and OPNsense completed its main boot and final startup hooks. Its snapshots contained only `lo0`: the kernel reported a non-FreeBSD firmware DTB and both PCIe buses returned many phantom `vendor=0x0000` devices instead of the onboard RTL8125B controllers. A first attempted `fdt_file` override appeared in `kenv` but changed neither the kernel's DTB-compliance warning nor PCI enumeration. Inspection of FreeBSD 15.1's EFI loader showed why: unlike the U-Boot loader backend, its EFI backend only retrieves the firmware configuration-table DTB. Preloading the FreeBSD-built R5C file as a loader object of type `dtb` removed that warning and corrected PCI enumeration: the next test found both physical `10ec:8125` controllers. The 1102.01 Realtek driver then failed both attaches with `unknown device`, leaving only `lo0`. Restoring the original R5S port's 198.00 module made it load and claim both devices, but every MMIO read returned all ones (`TXCFG=0xffffffff`). Adding MEM64 support to the DesignWare host driver made it program CPU windows `0x340000000` and `0x380000000`, but the inherited FreeBSD 15.1 device tree still translated them to 32-bit PCI bus address `0x40000000`; the RTL8125 MMIO reads therefore remained all ones. Current upstream RK3568 definitions identity-map those 64-bit windows. The R5C overlay now supplies those current ranges so the NIC BARs remain above 4 GB on both sides of the iATU mapping. The current revision also keeps the correct kernel-only `vfs.root.mountfrom`, assigns headless defaults of LAN `re0` (`192.168.1.1/24`) and DHCP WAN `re1`, and retains the checkpoints in OPNsense's actual startup script.

### Common build issues

The wrapper exits on the first real error. Re-run the same Mac command after correcting a failure; the OPNsense build directories and downloaded distfiles remain in the VM, so completed work is normally reused. The exact source-commit manifest prevents a retry from silently mixing release tags.

- **UTM starts but no IPv4 address is discovered:** the guest agent is optional and is not reliable on every UTM/FreeBSD combination. In the VM run `ifconfig vtnet0`, then pass the address explicitly: `./build-r5c-utm.sh 26.7.4 192.168.65.3`.
- **No clipboard in the VM:** this workflow does not depend on clipboard sharing. Type the three short bootstrap commands from step 3, then perform the build from the Mac.
- **AppleDouble or extended-attribute errors while copying:** the launcher disables macOS metadata and ACLs when creating the transfer archive. Use the launcher rather than manually archiving the checkout.
- **`opnsense-update` checksum/size failure:** this happened when `ports` was at the `26.7` tag while the output was labeled `26.7.4`. Stage 1.1 now passes the full version to `make update`, verifies all five repositories at the exact tag, and removes generated sets when their recorded source commits do not match. Do not edit `distinfo` or bypass the checksum.
- **Missing versioned Perl:** stage 1.1 determines the exact interpreter required by the selected ports tag and installs that tagged Perl port when necessary.
- **`py312-* conflicts with py311-*`:** a reused VM can retain automatic Python build dependencies from an older ports snapshot. Stage 1.1 now removes only obsolete, automatically installed Python flavors in the R5C U-Boot dependency closure. It deliberately will not remove a package explicitly installed by the administrator.
- **`pkg-static: database version ... is newer ... but still compatible`:** this is a compatibility warning, not the failure. Continue reading for the first `*** Error code` or the final `Build stopped:` line.
- **`ctfconvert: ... doesn't have type data to convert`:** these messages are non-fatal when the kernel subsequently links and reports `Kernel build ... completed`.
- **A compile line appears stuck:** LLVM, Rust, OpenSSL, Perl, and link steps can be quiet for ten minutes or longer. In another SSH session run `top -aSH` or `ps auxww` and wait while compiler/linker processes are using CPU. Treat it as hung only after activity and disk usage have stopped for a sustained period.
- **`pkg` port fails during parallel targets:** stage 1.1 intentionally runs the ports framework's clean/build/reinstall targets serially; the port's own build may still use multiple CPUs.
- **Disk-space warning:** 50 GiB free is the minimum preflight threshold, not a comfortable allocation. A 100 GB UTM disk is recommended. Increase the virtual disk before retrying if `/usr` is nearly full.
- **Build failed and the important line scrolled away:** inspect `build-artifacts/VERSION/build-VERSION.log` on the Mac and `/root/opnsense-dev/build.VERSION.status` in the VM. The latter names the failed numbered stage.
- **Build succeeded but transfer failed:** leave the VM running and re-run the launcher, or copy the raw image with the SSH command in the installation section below. Do not delete the VM until the Mac checksum passes.
- **eMMC Tools says a ZIP needs `parameter.txt` or `partmap.txt`:** ZIP/TGZ files are treated as FriendlyELEC partition packages. A ZIP containing only the OPNsense `.img` is not a valid package. Use a gzip-compressed whole-disk file named `OPNsense-....img.gz`, generated with `--emmc-image` or the command below.
- **`--boot-only` says a base/kernel/packages set is missing:** the VM does not contain a complete build of that exact release, or its cached output was invalidated after a source-version change. Re-run without `--boot-only`.
- **Diagnostic image does not boot:** inspect all `R5C*` files on the card's FAT partition. No marker means failure no later than U-Boot/MMC access. `R5CUBOOT.OK` proves U-Boot can write the FAT filesystem; `R5CSCAN.OK` proves local bootflow scanning returned; `R5CEFI.OK` proves a valid EFI flow was selected; and `R5CBOOT.FAIL` means EFI was unavailable or returned. OPNsense then records `R5CINIT.OK`, `R5CFSTB.OK`, `R5CPHP.OK`, `R5CBOOT.OK`, and `R5CRC.OK` in order. The last one present identifies the completed startup stage. Copy back every matching `.TXT` snapshot and preserve the build log before changing another variable.
- **Power LED turns off:** LED state by itself is not a reliable boot result because firmware and the kernel can reconfigure GPIOs. On the diagnostic image, use the FAT marker and log files together with the LEDs.
- **Both RTL8125 devices appear in `pciconf`, but `ifconfig` has only `lo0`:** the first image using the stock 1102.01 module reported only `unknown device`. A follow-up image proved that `realtek-re-kmod198` and `/boot/modules/if_re.ko` loaded correctly, but both NICs returned `TXCFG=0xffffffff`. Two inherited FreeBSD 15.1 issues caused that path: DesignWare PCIe programmed only MEM32 ranges, and its older RK3568 device tree translated each 64-bit CPU window to a 32-bit PCI bus address. The R5C overlay now programs MEM64 iATU windows and uses current upstream identity-mapped 64-bit ranges (`0x340000000` and `0x380000000`). A later test exposed a build-cache trap: compiling an unqualified `ARM64` kernel did not replace the device-named `R5C_DIAG` kernel set reused by final assembly. The kernel stage now receives the selected device, forces that exact set to rebuild, and `verify-r5c-dtb.sh` decodes the DTB in both the set and final raw image before the build can succeed. A successful attach should create `re0` and `re1`; if it does not, return `R5CRC.TXT`, `R5CPCI.TXT`, and `R5CIFCFG.TXT`.
- **NICs attach but routed throughput is unexpectedly low:** first confirm the actual link in `R5CNET.TXT` or with `ifconfig re0` and `ifconfig re1`; it must say `2500Base-T <full-duplex>` on both sides for a 2.5 Gb test. The R5C schematic names separate RTL8125 `1GLED` and `25GLED` signals, but LED appearance is secondary evidence and can vary with orientation and activity. Test routing with `iperf3` between two wired hosts before relying on a browser-based Internet test. The live logger records link media, errors/drops, CPU frequency/load, thermal state, MSI-X/interrupt evidence, and traffic counters so a physical-link limit can be separated from CPU, firewall, or test-server limits.
- **HDMI remains blank:** this is expected with the current mainline U-Boot/FreeBSD path, not evidence that boot stopped. Confirm `efi_max_resolution="1x1"` in `R5C*.TXT`. A USB keyboard cannot make this framebuffer usable; use the FAT diagnostics, networking after the Realtek driver attaches, or an optional 3.3 V UART adapter.

### Run entirely inside FreeBSD

The UTM launcher is optional. On any suitable FreeBSD 15.1 ARM64 build host, run as root:

```sh
pkg install -y git
git clone https://github.com/alexanderjlynn/opnsense-r5c.git
cd opnsense-r5c/arm64-opnsense-build
sh build-r5c.sh             # default: 26.7.4
sh build-r5c.sh 26.7.4      # explicit release
sh build-r5c.sh --diagnostic 26.7.4
```

The raw image is written to `/usr/local/opnsense/build/26.7/aarch64/images/`. The runner validates and checks out the exact release tags, records source provenance, sets the ports/pkg/Git batch flags, stops immediately on a failed stage, and records its last stage in `/root/opnsense-dev/build.VERSION.status`.

After a successful full build, a same-release boot-chain-only rebuild is:

```sh
sh rebuild-r5c-boot.sh --diagnostic 26.7.4
sh rebuild-r5c-boot.sh 26.7.4
```

To copy a manually run build back to macOS without a shared folder, run this on the Mac and enter the FreeBSD root password:

```sh
ssh root@VM_ADDRESS "xz -T0 -c /usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" > OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz
```

## Install the image on a NanoPi R5C

### Which storage should be used?

Use a microSD card for the first boot and hardware test, then use eMMC for a permanent firewall. SD is removable and gives the easiest recovery path; eMMC is internal, avoids dependence on a removable card, and is the simplest permanent layout. The current build intentionally does not support NVMe boot. The same whole-disk R5C image is used for SD and eMMC.

The build image starts at 4 GB. Its first-boot marker invokes the included partition/growfs logic, so the UFS root filesystem expands to use the remaining SD/eMMC space. Allow the first boot extra time and do not interrupt it while the filesystem is being grown.

The R5C has 32 GB eMMC and UHS-I microSD, and its debug UART is 3.3 V at **1500000 baud, 8N1**. FriendlyELEC's board-specific installation and recovery procedures are in the [official NanoPi R5C wiki](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_R5C).

### Obtain an installable image

macOS `dd` needs the raw `.img`; FriendlyWrt's web flasher should receive a gzip-compressed whole-disk image named `.img.gz`. A normal ZIP containing the `.img` is interpreted as a multi-part FriendlyELEC firmware archive and fails because it has no `parameter.txt` or `partmap.txt`.

For future builds, add `--emmc-image` to the Mac launcher. If the raw `.img` is already in `build-artifacts`, macOS includes everything needed to make the correct file without installing software:

```sh
gzip -9 -k build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img
gzip -t build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.gz
```

This preserves the raw image and produces `OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.gz`. Confirm it is below the web page's 2 GB upload limit. If only the build VM has the raw image, retrieve it without installing anything on macOS:

```sh
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.65.3 \
  "cat /usr/local/opnsense/build/26.7/aarch64/images/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" \
  > build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img
```

Substitute the VM address and version. This prompts for the temporary root password and leaves no SSH host key behind. Confirm that the resulting file is several gigabytes and not empty before deleting the VM.

### Recommended first test: write a microSD card on macOS

These commands use only macOS tools. **`dd` destroys the selected disk, so verify `diskN` by size and name before pressing Return. Never copy the example device name blindly.**

```sh
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if="$PWD/build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img" of=/dev/rdiskN bs=4m
sync
diskutil eject /dev/diskN
```

For the first corrected boot test, use `R5C_DIAG` rather than `R5C_UBOOT`. Balena Etcher can decompress and write `OPNsense-26.7.4-arm-aarch64-R5C_DIAG.img.gz` directly; do not decompress it into the SD card's mounted filesystem. Start the first boot with both Ethernet cables disconnected because the original R5S instructions noted that the 1.98 driver may require that once. Wait five minutes, or remove the card and confirm `R5CRC.OK`, then connect the LAN cable. Try DHCP first; if no lease appears, temporarily assign the Mac `192.168.1.2/24` and open `https://192.168.1.1`.

Press `Control-T` while macOS `dd` is running to display progress. No UART is required: if networking still does not appear, mount the card's FAT partition and run `ls -la /Volumes/MSDOSBOOT/R5C*`; copy back every `.TXT` file it contains. The most useful driver summary is `grep -E 'realtek-re|re[01]:|TXCFG|ifconfig|10ec|8125' /Volumes/MSDOSBOOT/R5CRC.TXT`. Ethernet link is not expected until FreeBSD starts. A 3.3 V USB-to-TTL adapter at 1500000 baud remains the strongest optional diagnostic; never connect its VCC pin. Keep the original eMMC unchanged until networking, both RTL8125B interfaces, and rebooting have been tested.

If a valid SD image is ignored, consult FriendlyELEC's Maskrom/unbrick procedure. An incompatible bootloader on eMMC may need to be erased before normal SD boot is restored.

### Recommended permanent install: FriendlyWrt eMMC Tools

For R5Cs that already have FriendlyELEC software, this is the easiest route and avoids Rockchip USB tooling:

1. Boot FriendlyWrt from a microSD card so the eMMC is the target, not the running root disk.
2. Connect to the LAN side and open `http://192.168.2.1/` (or the address configured on that device).
3. Open **System → eMMC Tools**, select the OPNsense `.img.gz`, then choose **Upload and Write**.
4. Wait for completion, shut down if the interface asks, remove the SD card, and power-cycle the board.

FriendlyELEC uses `XYZ.img.gz` for complete SD/eMMC images. Although the page also accepts `.tgz` and `.zip`, those formats can represent partition packages and are not equivalent to zipping a raw image. `.xz` is not listed. A full image overwrites the eMMC, including FriendlyWrt and its configuration.

### Alternative permanent install: FriendlyELEC eFlasher card

This is useful for repeated or headless deployment:

1. Download FriendlyELEC's R5C `eflasher` or `eflasher-multiple-os` image and write it to a sufficiently large SD card.
2. Mount the SD card's `FriendlyARM` partition on the Mac.
3. Copy the OPNsense raw `.img` there and rename its suffix from `.img` to `.raw`.
4. For unattended flashing, set `autoStart=` in `eflasher.conf` to that `.raw` filename. The multiple-OS image can instead be selected interactively.
5. Boot the R5C from this card, wait for eFlasher to finish, remove the card, and reboot from eMMC.

FriendlyELEC explicitly documents third-party `.raw` images for eFlasher. Back up anything needed from eMMC first; automatic mode begins writing after boot.

### Advanced: stream from an SD-booted OPNsense system to eMMC

This avoids storing another copy on the SD card. First use the serial console or an SSH shell on the R5C to identify the disks:

```sh
sysctl kern.disks
mount
gpart show
```

The disk containing the mounted root filesystem is the SD source. Only after confirming the other `mmcsd` disk is the eMMC, stream the compressed image from the Mac, replacing `mmcsdX` with the verified target:

```sh
# Confirm /usr/bin/xz is present on the SD-booted R5C first.
ssh root@R5C_ADDRESS 'command -v xz'
cat build-artifacts/26.7.4/OPNsense-26.7.4-arm-aarch64-R5C_UBOOT.img.xz | \
  ssh root@R5C_ADDRESS 'xz -dc | dd of=/dev/mmcsdX bs=1m conv=sync'
```

If `xz` is unavailable, use the raw `.img` from `--keep-raw` and pipe it directly to the same `dd` command. SSH must first be enabled on the temporary SD installation. Run `sync`, shut the board down, remove the SD card, and power it on again. This command overwrites the target immediately and has no confirmation prompt.

### USB-to-eMMC / Maskrom

The R5C supports Rockchip Maskrom flashing over the USB Type-A port nearest the TF slot. FriendlyELEC's procedure is to hold **MASK**, apply power, wait at least three seconds, release it, and connect that port to the flashing computer with a USB A-to-A data cable. Its Windows RKDevTool flow can erase eMMC and flash a single third-party image.

This is a recovery/production option, but it is not the recommended direct-Mac route: FriendlyELEC reports that `upgrade_tool_v2.25` does not work correctly on macOS and recommends Windows or Linux. A disposable Linux VM with USB passthrough or a Windows machine can be used, together with the R5C `MiniLoaderAll.bin` and tools from FriendlyELEC's USB package. If RKDevTool rejects the raw OPNsense image as a firmware container, stop and use eFlasher or the SD-to-eMMC streaming method; do not guess partition offsets. The upstream [Rockchip `rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool) can write sectors from Linux, but it also requires the correct RK3568 loader and careful target handling.

## Caveats

- The original R5S instructions reported that first boot with the 1.98 Realtek driver may require all network cables disconnected. First test the R5C with cables disconnected; connect to LAN after the full `R5CRC.OK` marker appears or after waiting five minutes.

## News

- 2026-09-30: Added a bounded live network logger to the diagnostic image after the first successful routed test reached only about 150 Mbps. It records negotiated link media and traffic/error counters alongside CPU, thermal, interrupt, driver, and PCIe state in `R5CNET.TXT`. Also corrected the diagnostic `ofwdump` option order so PCIe `ranges` are captured without a spurious node error.
- 2026-09-30: Physical logs from the first identity-range test still showed stale 32-bit PCI bus addresses. The source DTB was correct, but the boot-only wrapper rebuilt an `ARM64` kernel set while final assembly reused the cached `R5C_DIAG` set. Kernel builds now receive the selected device explicitly, and a new verifier checks the DTB inside both the device kernel set and final raw image. A fresh diagnostic image passed both checks, signature verification, local SHA-256 verification, and `gzip -t`. Physical testing then confirmed working LAN DHCP, access to the OPNsense web interface and console menu, and successful Internet traffic on the NanoPi R5C.
- 2026-09-29: A second driver test proved the 1.98 module loaded but read `TXCFG=0xffffffff` from both NICs. Added a FreeBSD DesignWare PCIe fix that creates outbound iATU windows for RK3568's MEM64 ranges. The resulting log showed those windows targeted stale 32-bit PCI addresses inherited by FreeBSD 15.1, so the R5C DTB now also uses current upstream RK3568 identity-mapped 64-bit PCI ranges. Added verbose iATU and raw PCI-register diagnostics.
- 2026-09-28: R5C boot path reduced to SD/eMMC only; added a packaged R5C DTB fallback, a multi-stage no-UART diagnostic image, and a cached boot-chain rebuild. Removed an invalid EFI `rootdev` override, preloaded the FreeBSD-compatible R5C DTB, and restored `realtek-re-kmod198` after physical logs proved the stock 1102.01 module rejected both correctly enumerated RTL8125 controllers. NVMe is retained only as an inactive future marker.
- 2026-07-18: Repository reworked for the NanoPi R5C and OPNsense 26.7 (FreeBSD 15.1): U-Boot boot via a local u-boot-nanopi-r5c port and stock realtek-re-kmod.
- 2026-05-21: 26.1.8 release used 26.1.7 packages and aux tar files. If needed, refer to 26.1.7 tar page. Package caddy-customs won't build as a result of its Github repository update.
- 2025-12-07: Due to storage problems and the Holiday Season, I won't be able to build 25.7.9 Images. In about two weeks I will have new hardware to rebuild the ARM64 box.
