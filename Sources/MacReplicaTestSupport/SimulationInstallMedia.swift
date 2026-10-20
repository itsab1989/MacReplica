import Foundation
import MacReplicaCore

/// Tools › Create macOS Installer on a simulated Mac: Software Update's catalog and download, Apple's support page,
/// drives and Apple's `createinstallmedia` – all stand-ins working on folders inside the simulated Mac, so the whole
/// flow, erase included, can be driven on screen without touching a real disk.
///
/// Drives live in `state/drives/<disk>/` (`media`, `size`, `bus`, `volume`, `content`, `uuid`, `partuuid`, optional
/// `internal` and `removable`); each has one partition `<disk>s2`, mounted when `Volumes/<volume>` exists. Switches: `state/erase-fails`, `state/createinstallmedia-fails` (their
/// text is the error), `state/unsigned` (the installer's signature fails), `state/offline` (Software Update fails).
extension SimulationRoot {
    public func addInstallMedia() throws {
        try SimulationBuilder.write(FakeInstallMedia.softwareupdate, to: url.appendingPathComponent("tools/softwareupdate"), executable: true)
        try SimulationBuilder.write(FakeInstallMedia.diskutil, to: url.appendingPathComponent("tools/diskutil"), executable: true)
        try SimulationBuilder.write(FakeInstallMedia.bless, to: url.appendingPathComponent("tools/bless"), executable: true)
        try SimulationBuilder.write(FakeInstallMedia.codesign, to: url.appendingPathComponent("tools/codesign"), executable: true)
        try SimulationBuilder.write(FakeInstallMedia.createinstallmedia, to: url.appendingPathComponent("tools/createinstallmedia"), executable: true)
        try SimulationBuilder.write(FakeInstallMedia.installers, to: state.appendingPathComponent("installers.txt"), executable: false)
        try SimulationBuilder.write(FakeInstallMedia.applePage, to: url.appendingPathComponent("install-media/apple-102662.html"), executable: false)
        try addDrive("disk4", media: "SanDisk Ultra", size: 32_017_047_552, volume: "STICK")
        try addDrive("disk5", media: "Samsung T7", size: 1_000_204_886_016, volume: "Backup")
        try SimulationBuilder.write("{}", to: url.appendingPathComponent("Volumes/Backup/MacReplica Backup/MacReplica-Backup-2026-10-15-2234/manifest.json"),
                                    executable: false)
        // Far too small for any installer (the simulated installer is small, so the stick is smaller still).
        try addDrive("disk6", media: "Kingston DataTraveler", size: 1_000_000_000, volume: "KINGSTON")
        // A card in the built-in reader: macOS calls it internal, but it is removable.
        try addDrive("disk7", media: "Built In SDXC Reader", size: 63_864_569_856, volume: "EOS_DIGITAL", bus: "Secure Digital",
                     isInternal: true, removable: true, content: "Windows_NTFS")
        try SimulationBuilder.write("x", to: url.appendingPathComponent("Volumes/EOS_DIGITAL/DCIM/100CANON/IMG_0001.JPG"), executable: false)
        // The Mac's own second SSD with one empty ExFAT partition (the expert option).
        try addDrive("disk8", media: "APPLE SSD AP0512Z", size: 500_277_790_720, volume: "SPARE", bus: "Apple Fabric", isInternal: true,
                     content: "Microsoft Basic Data")
    }

    public func addDrive(_ disk: String, media: String, size: Int64, volume: String?, mounted: Bool = true, bus: String = "USB",
                         isInternal: Bool = false, removable: Bool = false, content: String = "Apple_HFS") throws {
        let folder = state.appendingPathComponent("drives/\(disk)")
        try SimulationBuilder.write(media, to: folder.appendingPathComponent("media"), executable: false)
        try SimulationBuilder.write(String(size), to: folder.appendingPathComponent("size"), executable: false)
        try SimulationBuilder.write(bus, to: folder.appendingPathComponent("bus"), executable: false)
        try SimulationBuilder.write(volume ?? "", to: folder.appendingPathComponent("volume"), executable: false)
        try SimulationBuilder.write(content, to: folder.appendingPathComponent("content"), executable: false)
        try SimulationBuilder.write(UUID().uuidString, to: folder.appendingPathComponent("uuid"), executable: false)
        try SimulationBuilder.write(UUID().uuidString, to: folder.appendingPathComponent("partuuid"), executable: false)
        for (flag, on) in [("internal", isInternal), ("removable", removable)] {
            let file = folder.appendingPathComponent(flag)
            if on { try SimulationBuilder.write("1", to: file, executable: false) } else { try? FileManager.default.removeItem(at: file) }
        }
        if let volume, mounted {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Volumes/\(volume)"), withIntermediateDirectories: true)
        }
    }

    /// Another drive takes the place (and the device number) of `disk` – what MacReplica must notice before erasing.
    public func swapDrive(_ disk: String) throws {
        try addDrive(disk, media: "LaCie Rugged", size: 2_000_398_934_016, volume: "Photos")
    }
}

enum FakeInstallMedia {
    /// The answer of `softwareupdate --list-full-installers` on the maintainer's Mac (macOS 27.0.1, 2026-10-19), abridged.
    static let installers = """
    * Title: macOS 27 Golden Gate, Version: 27.0.1, Size: 17955378KiB, Build: 26A434, Deferred: NO
    * Title: macOS 27 Golden Gate, Version: 27.0, Size: 17969056KiB, Build: 26A428, Deferred: NO
    * Title: macOS Tahoe, Version: 26.7.1, Size: 17950170KiB, Build: 25G241, Deferred: NO
    * Title: macOS Tahoe, Version: 26.7, Size: 17950170KiB, Build: 25G233, Deferred: NO
    * Title: macOS Sequoia, Version: 15.8.1, Size: 15624816KiB, Build: 24H222, Deferred: NO
    * Title: macOS Sonoma, Version: 14.8.9, Size: 13334756KiB, Build: 23J631, Deferred: NO

    """

    /// The download links of support.apple.com/102662 as served on 2026-10-19 (anchors only).
    static let applePage = #"""
    <html><body>
    <a href="macappstores://apps.apple.com/app/macos-sequoia/id6596773750?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Sequoia 15</a>
    <a href="macappstores://apps.apple.com/app/macos-sonoma/id6450717509?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Sonoma 14</a>
    <a href="macappstores://apps.apple.com/app/macos-ventura/id1638787999?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Ventura 13</a>
    <a href="macappstores://apps.apple.com/app/macos-monterey/id1576738294?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Monterey 12</a>
    <a href="macappstores://apps.apple.com/app/macos-big-sur/id1526878132?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Big Sur 11</a>
    <a href="macappstores://apps.apple.com/app/macos-catalina/id1466841314?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Catalina 10.15</a>
    <a href="macappstores://apps.apple.com/app/macos-mojave/id1398502828?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS Mojave 10.14</a>
    <a href="macappstores://apps.apple.com/app/macos-high-sierra/id1246284741?mt&#x3D;12" class="gb-anchor" link-type="External link">macOS High Sierra 10.13</a>
    <a href="http://updates-http.cdn-apple.com/2019/cert/061-39476-20191023-48f365f4-0015-4c41-9f44-39d3d2aca067/InstallOS.dmg" class="gb-anchor" link-type="Downloads">Sierra 10.12</a>
    <a href="http://updates-http.cdn-apple.com/2019/cert/061-41424-20191024-218af9ec-cf50-4516-9011-228c78eda3d2/InstallMacOSX.dmg" class="gb-anchor" link-type="Downloads">El Capitan 10.11</a>
    <a href="http://updates-http.cdn-apple.com/2019/cert/061-41343-20191023-02465f92-3ab5-4c92-bfe2-b725447a070d/InstallMacOSX.dmg" class="gb-anchor" link-type="Downloads">Yosemite 10.10</a>
    <a href="https://updates.cdn-apple.com/2021/macos/031-0627-20210614-90D11F33-1A65-42DD-BBEA-E1D9F43A6B3F/InstallMacOSX.dmg" class="gb-anchor" link-type="Downloads">Mountain Lion 10.8</a>
    <a href="https://updates.cdn-apple.com/2021/macos/041-7683-20210614-E610947E-C7CE-46EB-8860-D26D71F0D3EA/InstallMacOSX.dmg" class="gb-anchor" link-type="Downloads">Lion 10.7</a>
    </body></html>
    """#

    static let softwareupdate = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "softwareupdate $*"
    case "${1:-}" in
      --list-full-installers)
        sim_delay
        echo "Finding available software"
        if [ -f "$S/offline" ]; then echo "Install failed with error: The network connection was lost." >&2; exit 1; fi
        echo "Software Update found the following full installers:"
        cat "$S/installers.txt" ;;
      --fetch-full-installer)
        version="${3:-}"
        echo "Scanning for $version installer"
        if [ -f "$S/offline" ]; then echo "Install failed with error: The network connection was lost."; exit 1; fi
        line="$(grep "Version: $version," "$S/installers.txt" | head -n 1)"
        [ -n "$line" ] || { echo "Install failed with error: Update not found"; exit 1; }
        title="$(printf '%s' "$line" | sed -n 's/^\* Title: \([^,]*\),.*/\1/p')"
        for p in 0 10 20 30 40 50 60 70 80 90 100; do printf '\rInstalling: %s.0%%' "$p"; sim_delay; sleep 0.2; done
        echo
        app="$ROOT/Applications/Install $title.app"
        rm -rf "$app"
        mkdir -p "$app/Contents/Resources" "$app/Contents/SharedSupport"
        cat > "$app/Contents/Info.plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.apple.InstallAssistant.simulated</string>
    <key>CFBundleDisplayName</key><string>Install $title</string>
    <key>CFBundleShortVersionString</key><string>$version.1</string>
    </dict></plist>
    PLIST
        cat > "$app/Contents/SharedSupport/InstallInfo.plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>System Image Info</key><dict><key>version</key><string>$version</string></dict></dict></plist>
    PLIST
        dd if=/dev/zero of="$app/Contents/SharedSupport/SharedSupport.dmg" bs=1m count=12 2>/dev/null
        dd if=/dev/zero of="$app/Contents/SharedSupport/BaseSystem.dmg" bs=1m count=12 2>/dev/null
        cp "$ROOT/tools/createinstallmedia" "$app/Contents/Resources/createinstallmedia"
        chmod 755 "$app/Contents/Resources/createinstallmedia"
        echo "Install finished successfully" ;;
      *) echo "softwareupdate (simulated): unsupported $*" >&2; exit 1 ;;
    esac
    """#

    static let diskutil = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "diskutil $*"
    D="$S/drives"
    V="$ROOT/Volumes"
    val() { cat "$D/$1/$2" 2>/dev/null; }
    esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
    head_plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n'; }
    partitions() {
      local d="$1" name; name="$(val "$d" volume)"
      [ -n "$name" ] || return 0
      printf '<dict><key>DeviceIdentifier</key><string>%ss2</string><key>Content</key><string>%s</string><key>VolumeName</key><string>%s</string><key>VolumeUUID</key><string>%s</string><key>DiskUUID</key><string>%s</string><key>Size</key><integer>%s</integer>' \
        "$d" "$(val "$d" content)" "$(printf '%s' "$name" | esc)" "$(val "$d" uuid)" "$(val "$d" partuuid)" "$(val "$d" size)"
      if [ -d "$V/$name" ]; then printf '<key>MountPoint</key><string>%s</string>' "$(printf '%s' "$V/$name" | esc)"; fi
      printf '</dict>'
    }
    entry() {
      printf '<dict><key>DeviceIdentifier</key><string>%s</string><key>Content</key><string>GUID_partition_scheme</string><key>Size</key><integer>%s</integer><key>Partitions</key><array>' "$1" "$(val "$1" size)"
      partitions "$1"
      printf '</array></dict>'
    }
    case "${1:-}" in
      list)
        head_plist; printf '<dict><key>AllDisksAndPartitions</key><array>'
        if [ -z "${3:-}" ] || [ "${3:-}" = external ]; then for d in $(ls "$D" 2>/dev/null); do entry "$d"; done
        elif [ -n "${3:-}" ] && [ -d "$D/${3}" ]; then entry "$3"; fi
        printf '</array></dict></plist>\n' ;;
      info)
        disk="${3:-}"
        if [ "$disk" = / ]; then
          head_plist
          printf '<dict><key>ParentWholeDisk</key><string>disk3</string><key>MountPoint</key><string>/</string><key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk0s2</string></dict></array></dict></plist>\n'
          exit 0
        fi
        case "$disk" in
          disk*s2)
            # A volume: its size and how much is on it (what MacReplica measures while an installer is written).
            parent="${disk%s2}"
            [ -d "$D/$parent" ] || { echo "Could not find disk: $disk" >&2; exit 1; }
            name="$(val "$parent" volume)"; total="$(val "$parent" size)"; used=0
            if [ -n "$name" ] && [ -d "$V/$name" ]; then used=$(( $(du -sk "$V/$name" | cut -f1) * 1024 )); fi
            head_plist
            printf '<dict><key>DeviceIdentifier</key><string>%s</string><key>VolumeName</key><string>%s</string><key>TotalSize</key><integer>%s</integer><key>FreeSpace</key><integer>%s</integer></dict></plist>\n' \
              "$disk" "$(printf '%s' "$name" | esc)" "$total" "$(( total - used ))"
            exit 0 ;;
        esac
        [ -n "$disk" ] && [ -d "$D/$disk" ] || { echo "Could not find disk: $disk" >&2; exit 1; }
        head_plist
        internal='<false/>'; [ -f "$D/$disk/internal" ] && internal='<true/>'
        removable='<false/>'; [ -f "$D/$disk/removable" ] && removable='<true/>'
        printf '<dict><key>DeviceIdentifier</key><string>%s</string><key>MediaName</key><string>%s</string><key>TotalSize</key><integer>%s</integer><key>BusProtocol</key><string>%s</string><key>Internal</key>%s<key>RemovableMedia</key>%s<key>VirtualOrPhysical</key><string>Physical</string><key>WritableMedia</key><true/><key>WholeDisk</key><true/></dict></plist>\n' \
          "$disk" "$(val "$disk" media | esc)" "$(val "$disk" size)" "$(val "$disk" bus)" "$internal" "$removable" ;;
      eraseVolume)
        # eraseVolume JHFS+ <name> <partition UUID>: only the partition with that identifier.
        name="${3:-}"; target="${4:-}"
        for d in $(ls "$D" 2>/dev/null); do
          if [ "$(val "$d" partuuid)" = "$target" ]; then
            echo "Started erase on ${d}s2"
            if [ -f "$S/erase-fails" ]; then cat "$S/erase-fails" >&2; exit 1; fi
            old="$(val "$d" volume)"; if [ -n "$old" ]; then rm -rf "$V/$old"; fi
            printf '%s' "$name" > "$D/$d/volume"; printf 'Apple_HFS' > "$D/$d/content"; uuidgen > "$D/$d/uuid"
            mkdir -p "$V/$name"
            echo "Finished erase on ${d}s2 ($name)"
            exit 0
          fi
        done
        echo "Could not find disk: $target" >&2; exit 1 ;;
      eraseDisk)
        name="${3:-}"; disk="${5:-}"
        [ -n "$disk" ] && [ -d "$D/$disk" ] || { echo "Could not find disk: $disk" >&2; exit 1; }
        echo "Started erase on $disk"
        if [ -f "$S/erase-fails" ]; then cat "$S/erase-fails" >&2; exit 1; fi
        sim_delay
        old="$(val "$disk" volume)"
        if [ -n "$old" ]; then rm -rf "$V/$old"; fi
        echo "Unmounting disk"
        echo "Creating the partition map"
        echo "Formatting ${disk}s2 as Mac OS Extended (Journaled) with name $name"
        printf '%s' "$name" > "$D/$disk/volume"; printf 'Apple_HFS' > "$D/$disk/content"; uuidgen > "$D/$disk/uuid"
        mkdir -p "$V/$name"
        echo "Mounting disk"
        echo "Finished erase on $disk" ;;
      *) echo "diskutil (simulated): unsupported $*" >&2; exit 1 ;;
    esac
    """#

    /// `bless --info` of a simulated installer drive.
    static let bless = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "bless $*"
    [ "${1:-}" = "--info" ] && [ -f "${2:-}/System/Library/CoreServices/boot.efi" ] || { echo "Can't access \"${2:-}\"" >&2; exit 1; }
    echo "finderinfo[0]:      2 => Blessed System Folder is ${2}/System/Library/CoreServices"
    """#

    /// Apple's signature of the simulated installers; everything else is asked of the real codesign.
    static let codesign = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    last="${!#}"
    case "$last" in
      */Install\ *.app|*/Install\ *.app/Contents/Resources/createinstallmedia)
        log_call "codesign $*"
        if [ -f "$S/unsigned" ]; then echo "$last: a sealed resource is missing or invalid" >&2; exit 1; fi
        [ -f "$last/Contents/Info.plist" ] || [ -x "$last" ] || { echo "$last: code object is not signed at all" >&2; exit 1; }
        exit 0 ;;
    esac
    exec /usr/bin/codesign "$@"
    """#

    /// Apple's `createinstallmedia`, as far as MacReplica sees it: erases and renames the volume, copies the
    /// installer and makes the drive startable.
    static let createinstallmedia = #"""
    #!/bin/bash
    set -u
    ROOT="${MACREPLICA_SIMULATION_ROOT:?}"; S="$ROOT/state"
    echo "createinstallmedia $*" >> "$S/calls.log"
    if [ $# -eq 0 ]; then
      echo "Usage: createinstallmedia --volume <path to volume to convert>"
      echo "--volume, A path to a volume that can be unmounted and erased to create the install media."
      echo "--nointeraction, Erase the disk pointed to by volume without prompting for confirmation."
      echo "--downloadassets, Download on-demand assets that may be required for installation."
      echo "This tool must be run as root."
      exit 0
    fi
    vol=""; quiet=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --volume) vol="$2"; shift 2 ;;
        --nointeraction) quiet=1; shift ;;
        --applicationpath) shift 2 ;;
        *) echo "Usage: createinstallmedia --volume <path> [--nointeraction] [--downloadassets]" >&2; exit 1 ;;
      esac
    done
    [ "$quiet" = 1 ] || { echo "To continue we need to erase the volume at $vol."; exit 1; }
    [ -d "$vol" ] || { echo "$vol is not a valid volume mount point." >&2; exit 1; }
    app="$(cd "$(dirname "$0")/../.." && pwd)"
    name="$(basename "$app" .app)"
    if [ -f "$S/createinstallmedia-fails" ]; then echo "Erasing disk: 0%... 10%..."; cat "$S/createinstallmedia-fails" >&2; exit 1; fi
    pause() { if [ -f "$S/delay" ]; then sleep "$(cat "$S/delay")"; fi; }
    echo "Erasing disk: 0%... 10%... 20%... 30%... 100%"
    new="$(dirname "$vol")/$name"
    rm -rf "$new"; mv "$vol" "$new"; find "$new" -mindepth 1 -delete
    for d in "$S"/drives/*; do
      if [ "$(cat "$d/volume" 2>/dev/null)" = "$(basename "$vol")" ]; then printf '%s' "$name" > "$d/volume"; fi
    done
    pause; echo "Copying essential files..."
    mkdir -p "$new/$name.app/Contents/Resources" "$new/System/Library/CoreServices"
    cp "$app/Contents/Info.plist" "$new/$name.app/Contents/Info.plist"
    # The installer's data, in two halves with a pause between (so the progress shows on screen).
    if [ -d "$app/Contents/SharedSupport" ]; then
      mkdir -p "$new/$name.app/Contents/SharedSupport"
      for f in "$app/Contents/SharedSupport"/*; do pause; cp "$f" "$new/$name.app/Contents/SharedSupport/"; done
    fi
    printf 'efi' > "$new/System/Library/CoreServices/boot.efi"
    pause; echo "Making disk bootable..."
    echo "Copying boot files..."
    echo "Install media now available at \"$new\""
    """#
}
