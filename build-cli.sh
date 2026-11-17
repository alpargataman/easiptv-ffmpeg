#!/usr/bin/env bash
# Builds the FFmpeg command line tool EasIPTV Player runs to read RTSP: it only
# remuxes (-c copy) an RTSP session into MPEG-TS on its standard output, or into
# a fragmented MP4 file to record audio MPEG-TS does not carry (the file
# protocol is there for that output only). FFmpeg is LGPL-2.1+ only,
# without encoders or decoders, plus the patches of patches/cli (published in
# changes.diff). The executable of each ABI is
# named libffmpeg_rtsp.so so that Android installs it in the app's native
# library directory, the one place an app may execute files from (W^X, API 29+),
# and ships in an AAR (jni/<abi>/libffmpeg_rtsp.so) that the app consumes like
# the decoder.
#
# Usage: ./build-cli.sh   (after ./build-decoder.sh when both go in one release:
# that script empties dist/, this one adds its files and rewrites SHA256SUMS)
# Requires: ANDROID_HOME (or ANDROID_SDK_ROOT) with ndk;$NDK_VERSION, git, make, patch, python3.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FFMPEG_SUBMODULE_DIR="$ROOT/external/ffmpeg"
readonly WORK_DIR="$ROOT/build/cli"
readonly DIST_DIR="$ROOT/dist"
readonly FFMPEG_BUILD_DIR="$WORK_DIR/ffmpeg"
readonly PATCH_DIR="$ROOT/patches/cli"
readonly EXECUTABLE_NAME="libffmpeg_rtsp.so"
readonly LICENSE_FILE="COPYING.LGPLv2.1"

fail() {
    echo "build-cli.sh: $*" >&2
    exit 1
}

# shellcheck source=versions.env
source "$ROOT/versions.env"
read -r -a ABI_LIST <<< "$ABIS"
IFS=, read -r -a MUXER_LIST <<< "$CLI_MUXERS"
IFS=, read -r -a PROTOCOL_LIST <<< "$CLI_PROTOCOLS"
# The rtsp demuxer selects http (RTSP over HTTP); the app's input whitelist leaves it out
readonly PROTOCOLS_SELECTED_BY_DEMUXERS="http"
readonly RELEASE_TAG="app-${APP_VERSION}-${BUILD_NUMBER}"
readonly AAR_NAME="lib-ffmpeg-rtsp-${FFMPEG_TAG}-${RELEASE_TAG}.aar"
readonly SOURCE_ARCHIVE="ffmpeg-$FFMPEG_TAG-source.tar.gz"

readonly SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "$SDK_DIR" ]] || fail "set ANDROID_HOME to the Android SDK"
readonly NDK_DIR="$SDK_DIR/ndk/$NDK_VERSION"
[[ -d "$NDK_DIR" ]] || fail "NDK $NDK_VERSION missing: sdkmanager --install 'ndk;$NDK_VERSION'"
readonly TOOLCHAIN_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -x "$TOOLCHAIN_BIN/llvm-readelf" ]] || fail "no linux-x86_64 LLVM toolchain in $NDK_DIR"

require_pinned_submodule() {
    local directory="$1" expected_commit="$2"
    local actual_commit
    actual_commit="$(git -C "$directory" rev-parse HEAD)"
    [[ "$actual_commit" == "$expected_commit" ]] \
        || fail "$directory is at $actual_commit, versions.env pins $expected_commit"
    [[ -z "$(git -C "$directory" status --porcelain --untracked-files=no)" ]] \
        || fail "$directory has local modifications; the build must use the pinned sources"
}

# Prints the configure options of one ABI: only the ffmpeg program, with the
# components of versions.env (CLI_*) and nothing else (--disable-everything,
# --disable-autodetect: no external library). Tools come from PATH and
# --disable-debug keeps build paths out of the binary (reproducible output).
configure_options_for() {
    local abi="$1"
    local -a options=(
        --target-os=android
        --enable-static --disable-shared
        --disable-doc --disable-everything --disable-autodetect
        --disable-ffplay --disable-ffprobe
        --disable-avdevice --disable-swscale --disable-swresample --disable-postproc
        --enable-small
        --enable-protocol="$CLI_PROTOCOLS"
        --enable-demuxer="$CLI_DEMUXERS"
        --enable-muxer="$CLI_MUXERS"
        --enable-parser="$CLI_PARSERS"
        --enable-bsf="$CLI_BSFS"
        --extra-ldexeflags=-pie
        --disable-debug
        --nm=llvm-nm --ar=llvm-ar --ranlib=llvm-ranlib --strip=llvm-strip
    )
    case "$abi" in
        armeabi-v7a)
            options+=(--arch=arm --cpu=armv7-a
                --cross-prefix="armv7a-linux-androideabi${ANDROID_API}-"
                "--extra-cflags=-march=armv7-a -mfloat-abi=softfp"
                --extra-ldflags=-Wl,--fix-cortex-a8) ;;
        arm64-v8a)
            options+=(--arch=aarch64 --cpu=armv8-a
                --cross-prefix="aarch64-linux-android${ANDROID_API}-") ;;
        x86)
            options+=(--arch=x86 --cpu=i686 --disable-asm
                --cross-prefix="i686-linux-android${ANDROID_API}-") ;;
        x86_64)
            options+=(--arch=x86_64 --cpu=x86-64 --disable-asm
                --cross-prefix="x86_64-linux-android${ANDROID_API}-") ;;
        *) fail "unsupported ABI $abi" ;;
    esac
    printf '%s\n' "${options[@]}"
}

# Fails unless the generated config.h is LGPL-2.1+ only and config_components.h
# has every muxer of CLI_MUXERS, exactly the protocols of CLI_PROTOCOLS (plus
# what the demuxers select: no TLS, nothing else) and no encoder or decoder.
require_lgpl_remuxer_config() {
    local config_header="$1" components_header="$2"
    local flag muxer enabled_protocols expected_protocols
    for flag in CONFIG_GPL CONFIG_NONFREE CONFIG_VERSION3; do
        grep -qx "#define $flag 0" "$config_header" || fail "$config_header does not have $flag 0"
    done
    grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"$' "$config_header" \
        || fail "$config_header is not LGPL version 2.1 or later"
    if grep -E '^#define FFMPEG_CONFIGURATION ' "$config_header" | grep -qE -- '--enable-(gpl|nonfree|version3)'; then
        fail "$config_header was configured with a GPL/nonfree/version3 switch"
    fi
    for muxer in "${MUXER_LIST[@]}"; do
        grep -qx "#define CONFIG_${muxer^^}_MUXER 1" "$components_header" || fail "$components_header has no $muxer muxer"
    done
    enabled_protocols="$(sed -nE 's/^#define CONFIG_([A-Z0-9_]+)_PROTOCOL 1$/\1/p' "$components_header" \
        | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort | tr '\n' ' ')"
    expected_protocols="$(printf '%s\n' "${PROTOCOL_LIST[@]}" "$PROTOCOLS_SELECTED_BY_DEMUXERS" | LC_ALL=C sort | tr '\n' ' ')"
    [[ "$enabled_protocols" == "$expected_protocols" ]] \
        || fail "$components_header enables the protocols '$enabled_protocols', expected '$expected_protocols'"
    if grep -E '^#define CONFIG_[A-Z0-9_]+_(ENCODER|DECODER) 1$' "$components_header"; then
        fail "$components_header enables an encoder or a decoder"
    fi
}

# Applies patches/cli/*.patch, in name order, to the extracted FFmpeg tree.
apply_patches() {
    local patch_file
    for patch_file in "$PATCH_DIR"/*.patch; do
        [[ -f "$patch_file" ]] || continue
        patch -p1 --batch --forward --no-backup-if-mismatch --quiet -d "$FFMPEG_BUILD_DIR" < "$patch_file" \
            || fail "$patch_file does not apply to FFmpeg $FFMPEG_TAG"
    done
}

# Prints the components a config_components.h enables, one line per kind.
enabled_components_of() {
    local components_header="$1" kind
    for kind in PROTOCOL DEMUXER MUXER PARSER BSF; do
        printf '%s: %s\n' "$kind" "$(sed -nE "s/^#define CONFIG_([A-Z0-9_]+)_${kind} 1$/\1/p" "$components_header" \
            | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    done
}

# Every ABI must enable the same components: the list in BUILD.md holds for all of them.
write_enabled_components() {
    local abi reference="$WORK_DIR/components.txt"
    enabled_components_of "$WORK_DIR/config_components-${ABI_LIST[0]}.h" > "$reference"
    for abi in "${ABI_LIST[@]}"; do
        enabled_components_of "$WORK_DIR/config_components-$abi.h" | cmp -s - "$reference" \
            || fail "$abi enables other components than ${ABI_LIST[0]}"
    done
}

run_logged() {
    local log="$1"
    shift
    "$@" >> "$log" 2>&1 || { tail -n 40 "$log" >&2; fail "'$*' failed (see $log)"; }
}

build_executable_for() {
    local abi="$1"
    local -a options
    mapfile -t options < <(configure_options_for "$abi")
    echo "== FFmpeg $FFMPEG_TAG CLI for $abi"
    (
        cd "$FFMPEG_BUILD_DIR"
        export PATH="$TOOLCHAIN_BIN:$PATH"
        run_logged "$WORK_DIR/configure-$abi.log" ./configure "${options[@]}"
        require_lgpl_remuxer_config config.h config_components.h
        cp config.h "$WORK_DIR/config-$abi.h"
        cp config_components.h "$WORK_DIR/config_components-$abi.h"
        run_logged "$WORK_DIR/make-$abi.log" make -j"$(nproc)" ffmpeg
        mkdir -p "$WORK_DIR/jni/$abi"
        cp ffmpeg "$WORK_DIR/jni/$abi/$EXECUTABLE_NAME"
        run_logged "$WORK_DIR/make-$abi.log" make distclean
    )
    # Options with a space are quoted, so that the line in BUILD.md can be pasted as it is
    local option configure_line='./configure'
    for option in "${options[@]}"; do
        [[ "$option" == *' '* ]] && option="'$option'"
        configure_line+=" $option"
    done
    printf '%s\n' "$configure_line" > "$WORK_DIR/configure-line-$abi.txt"
}

# One executable per ABI: PIE, 16 KiB LOAD alignment on 64-bit ABIs and a
# 16 KiB-safe RELRO (scripts/check-relro.sh).
verify_executables() {
    local abi executable elf_header program_headers alignments
    : > "$WORK_DIR/elf.txt"
    for abi in "${ABI_LIST[@]}"; do
        executable="$WORK_DIR/jni/$abi/$EXECUTABLE_NAME"
        [[ -s "$executable" ]] || fail "no $abi/$EXECUTABLE_NAME"
        # Read whole before grep -q: with pipefail, grep -q quitting early fails readelf with SIGPIPE
        elf_header="$("$TOOLCHAIN_BIN/llvm-readelf" -hW "$executable")"
        program_headers="$("$TOOLCHAIN_BIN/llvm-readelf" -lW "$executable")"
        grep -q 'Type:.*DYN' <<< "$elf_header" || fail "$abi/$EXECUTABLE_NAME is not a PIE"
        grep -q 'Requesting program interpreter: /system/bin/linker' <<< "$program_headers" \
            || fail "$abi/$EXECUTABLE_NAME is not an Android executable"
        alignments="$(awk '$1 == "LOAD" { print $NF }' <<< "$program_headers" | sort -u | tr '\n' ' ')"
        printf '%s %s: %s bytes, LOAD alignment %s\n' "$abi" "$EXECUTABLE_NAME" "$(stat -c %s "$executable")" "$alignments" >> "$WORK_DIR/elf.txt"
        if [[ "$abi" == arm64-v8a || "$abi" == x86_64 ]] && [[ "$alignments" != "0x4000 " ]]; then
            fail "$abi/$EXECUTABLE_NAME is not 16 KiB aligned ($alignments)"
        fi
    done
    READELF="$TOOLCHAIN_BIN/llvm-readelf" bash "$ROOT/scripts/check-relro.sh" "$WORK_DIR/jni" > "$WORK_DIR/relro.txt" \
        || { cat "$WORK_DIR/relro.txt" >&2; fail "RELRO check failed"; }
}

# The AAR the app consumes: native libraries only, packed byte for byte the same
# on every build (fixed entry order, times and permissions, and no compression:
# deflate output depends on the zlib of the machine; the APK compresses them).
write_aar() {
    python3 -I - "$WORK_DIR" "$DIST_DIR/$AAR_NAME" "$ANDROID_API" "$EXECUTABLE_NAME" "${ABI_LIST[@]}" <<'PY'
import io, sys, zipfile
work_dir, aar, min_sdk, executable, *abis = sys.argv[1:]
stamp = (1981, 1, 1, 0, 0, 0)

def entry(name, mode):
    info = zipfile.ZipInfo(name, stamp)
    info.compress_type = zipfile.ZIP_STORED
    info.create_system = 3
    info.external_attr = (0o100000 | mode) << 16
    return info

empty_jar = io.BytesIO()
with zipfile.ZipFile(empty_jar, "w") as jar:
    jar.writestr(entry("META-INF/MANIFEST.MF", 0o644), "Manifest-Version: 1.0\r\n\r\n")
manifest = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.easiptv.ffmpeg.rtsp">\n'
    f'    <uses-sdk android:minSdkVersion="{min_sdk}" />\n'
    '</manifest>\n'
)
with zipfile.ZipFile(aar, "w") as archive:
    archive.writestr(entry("AndroidManifest.xml", 0o644), manifest)
    archive.writestr(entry("R.txt", 0o644), "")
    archive.writestr(entry("classes.jar", 0o644), empty_jar.getvalue())
    for abi in abis:
        with open(f"{work_dir}/jni/{abi}/{executable}", "rb") as binary:
            archive.writestr(entry(f"jni/{abi}/{executable}", 0o755), binary.read())
PY
}

write_build_notes() {
    local abi patch_file
    # A rebuild replaces its own section of BUILD.md (the decoder's comes first)
    [[ -f "$DIST_DIR/BUILD.md" ]] && sed -i '/^# FFmpeg command line tool for RTSP/,$d' "$DIST_DIR/BUILD.md"
    {
        printf '# FFmpeg command line tool for RTSP — %s\n\n' "$RELEASE_TAG"
        printf '`%s` holds `jni/<abi>/%s`: the `ffmpeg` program of FFmpeg %s (`%s`), LGPL version 2.1 or later\n' \
            "$AAR_NAME" "$EXECUTABLE_NAME" "$FFMPEG_TAG" "$FFMPEG_COMMIT"
        printf '(`CONFIG_GPL 0`, `CONFIG_NONFREE 0`, `CONFIG_VERSION3 0`), without encoders or decoders. EasIPTV Player runs it as\n'
        printf '`ffmpeg -protocol_whitelist tcp,udp,rtp -i rtsp://… -c copy -f mpegts pipe:1` and reads the MPEG-TS from its\n'
        printf 'standard output. To record audio that MPEG-TS does not carry it writes a fragmented MP4 file instead, with\n'
        printf 'the variant of the mov muxer that takes the codec: `-f mov` for G.711, `-f 3gp` for AMR-NB/WB, `-f mp4` for\n'
        printf 'Opus (and AAC), and `-movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration <µs> -flush_packets 1`.\n\n'
        printf '**The `file` protocol is there to write that recording only.** `-protocol_whitelist tcp,udp,rtp` is an input\n'
        printf 'option: with it the input cannot open `file:`/plain paths, `pipe:` or `http` (also RTSP over HTTP), RTSP\n'
        printf 'redirects reconnect over RTSP/TCP only, and `concat:`, `subfile:`, `fd:` and TLS are not built.\n\n'
        printf '| Input | Value |\n|---|---|\n'
        printf '| Android NDK | %s |\n' "$NDK_VERSION"
        printf '| Minimum API | %s |\n' "$ANDROID_API"
        printf '| ABIs | %s |\n' "$ABIS"
        printf '| Protocols | %s |\n' "$CLI_PROTOCOLS"
        printf '| Demuxers | %s (and what they select: see the configure logs) |\n' "$CLI_DEMUXERS"
        printf '| Muxers | %s |\n' "$CLI_MUXERS"
        printf '| Parsers | %s |\n' "$CLI_PARSERS"
        printf '| Bitstream filters | %s |\n\n' "$CLI_BSFS"
        printf '## Enabled components\n\nWhat `config_components.h` enables on every ABI (the options above plus what they select); no encoder and no decoder.\n\n```\n%s\n```\n\n' "$(cat "$WORK_DIR/components.txt")"
        printf '## Changes to FFmpeg\n\nApplied with `patch -p1` to the tree of `%s` before `configure`, in this order; their full text is in `changes.diff` and in `patches/cli` of the repository:\n\n' "$SOURCE_ARCHIVE"
        for patch_file in "$PATCH_DIR"/*.patch; do
            [[ -f "$patch_file" ]] || continue
            printf -- '- `%s`: %s\n' "$(basename "$patch_file")" "$(sed -n '1p' "$patch_file")"
        done
        printf '\n## FFmpeg configure lines\n\nRun inside the FFmpeg source tree (`%s` with the patches above, plus a `VERSION` file that holds `%s`) with the NDK `toolchains/llvm/prebuilt/linux-x86_64/bin` first in `PATH`, then `make ffmpeg`; the stripped `ffmpeg` is `%s`.\n\n' "$SOURCE_ARCHIVE" "$FFMPEG_TAG" "$EXECUTABLE_NAME"
        for abi in "${ABI_LIST[@]}"; do
            printf '### %s\n\n```\n%s\n```\n\n' "$abi" "$(cat "$WORK_DIR/configure-line-$abi.txt")"
        done
        printf '## Executables\n\n```\n%s\n```\n\n```\n%s\n```\n\n' "$(cat "$WORK_DIR/elf.txt")" "$(cat "$WORK_DIR/relro.txt")"
        printf '```\n'
        for abi in "${ABI_LIST[@]}"; do
            (cd "$WORK_DIR/jni" && sha256sum "$abi/$EXECUTABLE_NAME")
        done
        printf '```\n\n'
        printf '## Rebuilding (LGPL-2.1)\n\nThe whole executable is FFmpeg code (license text: `%s`). To use a modified FFmpeg, replace `external/ffmpeg` (or the tree from `%s`) or add patches to `patches/cli`, and run `./build-cli.sh`; the resulting AAR replaces the one in the app.\n' "$LICENSE_FILE" "$SOURCE_ARCHIVE"
    } >> "$DIST_DIR/BUILD.md"
}

# Appends the patches of patches/cli to changes.diff (written by build-decoder.sh),
# replacing this script's section on a rebuild.
write_changes() {
    local changes="$DIST_DIR/changes.diff" marker="# Changes to FFmpeg $FFMPEG_TAG in the command line tool"
    [[ -f "$changes" ]] && sed -i "/^$marker/,\$d" "$changes"
    {
        printf '%s (build-cli.sh, patches/cli)\n' "$marker"
        local patch_file
        for patch_file in "$PATCH_DIR"/*.patch; do
            [[ -f "$patch_file" ]] || continue
            cat "$patch_file"
        done
    } >> "$changes"
}

write_checksums() {
    (
        cd "$DIST_DIR"
        find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
    )
}

main() {
    require_pinned_submodule "$FFMPEG_SUBMODULE_DIR" "$FFMPEG_COMMIT"
    rm -rf "$WORK_DIR" "$DIST_DIR/$AAR_NAME"
    mkdir -p "$WORK_DIR" "$DIST_DIR"
    # git archive is deterministic for a commit; gzip -n drops the timestamp (the decoder writes the same file)
    git -C "$FFMPEG_SUBMODULE_DIR" archive --format=tar --prefix="ffmpeg-$FFMPEG_TAG/" HEAD \
        | gzip -n -9 > "$DIST_DIR/$SOURCE_ARCHIVE"
    mkdir -p "$FFMPEG_BUILD_DIR"
    tar -xzf "$DIST_DIR/$SOURCE_ARCHIVE" -C "$FFMPEG_BUILD_DIR" --strip-components=1
    # ffbuild/version.sh would ask git, which finds this repository (its tags, its commit) around
    # the tree: the version that ffmpeg prints comes from VERSION instead, as in FFmpeg's tarballs
    printf '%s\n' "$FFMPEG_TAG" > "$FFMPEG_BUILD_DIR/VERSION"
    apply_patches
    cp "$FFMPEG_BUILD_DIR/$LICENSE_FILE" "$DIST_DIR/$LICENSE_FILE"
    local abi
    for abi in "${ABI_LIST[@]}"; do
        build_executable_for "$abi"
    done
    write_enabled_components
    verify_executables
    write_aar
    write_changes
    write_build_notes
    write_checksums
    echo "== Done: $DIST_DIR/$AAR_NAME"
    cat "$WORK_DIR/elf.txt"
    (cd "$WORK_DIR/jni" && sha256sum ./*/"$EXECUTABLE_NAME")
    cat "$DIST_DIR/SHA256SUMS"
}

main "$@"
