#!/usr/bin/env bash
# Builds the Media3 FFmpeg audio decoder (lib-decoder-ffmpeg AAR) from the
# pinned submodules, with FFmpeg under LGPL-2.1+ only, and assembles the
# release package in dist/.
#
# Usage: ./build-decoder.sh
# Requires: ANDROID_HOME (or ANDROID_SDK_ROOT) with ndk;$NDK_VERSION and
# cmake;$CMAKE_VERSION installed, JAVA_HOME pointing to a JDK 21, git, make,
# python3.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MEDIA_DIR="$ROOT/external/media"
readonly FFMPEG_SUBMODULE_DIR="$ROOT/external/ffmpeg"
readonly WORK_DIR="$ROOT/build"
readonly DIST_DIR="$ROOT/dist"
readonly FFMPEG_BUILD_DIR="$WORK_DIR/ffmpeg"
readonly JNI_FFMPEG_LINK="$MEDIA_DIR/libraries/decoder_ffmpeg/src/main/jni/ffmpeg"

fail() {
    echo "build-decoder.sh: $*" >&2
    exit 1
}

# shellcheck source=versions.env
source "$ROOT/versions.env"
read -r -a ABI_LIST <<< "$ABIS"
read -r -a DECODER_LIST <<< "$DECODERS"
readonly RELEASE_TAG="app-${APP_VERSION}-${BUILD_NUMBER}"
readonly AAR_NAME="lib-decoder-ffmpeg-${MEDIA3_TAG}-${RELEASE_TAG}.aar"

readonly SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "$SDK_DIR" ]] || fail "set ANDROID_HOME to the Android SDK"
readonly NDK_DIR="$SDK_DIR/ndk/$NDK_VERSION"
[[ -d "$NDK_DIR" ]] || fail "NDK $NDK_VERSION missing: sdkmanager --install 'ndk;$NDK_VERSION'"
[[ -d "$SDK_DIR/cmake/$CMAKE_VERSION" ]] || fail "CMake $CMAKE_VERSION missing: sdkmanager --install 'cmake;$CMAKE_VERSION'"
[[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME:-}/bin/java" ]] || fail "set JAVA_HOME to a JDK 21 (Gradle runs on it; javac output is part of the AAR)"
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

# Prints the configure options of one ABI. Same options as Media3's
# build_ffmpeg.sh, except: tools are resolved through PATH so the embedded
# configuration string carries no machine paths, and --disable-debug keeps
# absolute build paths out of the objects (reproducible output).
configure_options_for() {
    local abi="$1"
    local -a options=(
        --libdir="android-libs/$abi"
        --target-os=android
        --enable-static --disable-shared
        --disable-doc --disable-programs --disable-everything
        --disable-avdevice --disable-avformat --disable-swscale
        --disable-postproc --disable-avfilter --disable-symver
        --enable-swresample
        --extra-ldexeflags=-pie
        --disable-v4l2-m2m --disable-vulkan
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
    local decoder
    for decoder in "${DECODER_LIST[@]}"; do
        options+=(--enable-decoder="$decoder")
    done
    printf '%s\n' "${options[@]}"
}

# Fails unless the generated config.h is LGPL-2.1+ only.
require_lgpl_config() {
    local config_header="$1"
    local flag
    for flag in CONFIG_GPL CONFIG_NONFREE CONFIG_VERSION3; do
        grep -qx "#define $flag 0" "$config_header" || fail "$config_header does not have $flag 0"
    done
    grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"$' "$config_header" \
        || fail "$config_header is not LGPL version 2.1 or later"
    if grep -E '^#define FFMPEG_CONFIGURATION ' "$config_header" | grep -qE -- '--enable-(gpl|nonfree|version3)'; then
        fail "$config_header was configured with a GPL/nonfree/version3 switch"
    fi
}

# Runs a command appending its output to a log; on failure shows the log tail.
run_logged() {
    local log="$1"
    shift
    "$@" >> "$log" 2>&1 || { tail -n 40 "$log" >&2; fail "'$*' failed (see $log)"; }
}

build_ffmpeg_for() {
    local abi="$1"
    local -a options
    mapfile -t options < <(configure_options_for "$abi")
    echo "== FFmpeg $FFMPEG_TAG for $abi"
    (
        cd "$FFMPEG_BUILD_DIR"
        export PATH="$TOOLCHAIN_BIN:$PATH"
        run_logged "$WORK_DIR/configure-$abi.log" ./configure "${options[@]}"
        require_lgpl_config config.h
        cp config.h "$WORK_DIR/config-$abi.h"
        run_logged "$WORK_DIR/make-$abi.log" make -j"$(nproc)"
        run_logged "$WORK_DIR/make-$abi.log" make install-libs
        run_logged "$WORK_DIR/make-$abi.log" make clean
    )
    printf './configure %s\n' "${options[*]}" > "$WORK_DIR/configure-line-$abi.txt"
}

remove_jni_link() {
    [[ -L "$JNI_FFMPEG_LINK" ]] && rm -f "$JNI_FFMPEG_LINK"
    return 0
}

build_aar() {
    echo "== Media3 $MEDIA3_TAG :lib-decoder-ffmpeg"
    [[ ! -e "$JNI_FFMPEG_LINK" ]] || fail "$JNI_FFMPEG_LINK already exists"
    ln -s "$FFMPEG_BUILD_DIR" "$JNI_FFMPEG_LINK"
    trap remove_jni_link EXIT
    rm -rf "$MEDIA_DIR/libraries/decoder_ffmpeg/buildout" "$MEDIA_DIR/libraries/decoder_ffmpeg/.cxx"
    "$MEDIA_DIR/gradlew" -p "$MEDIA_DIR" --no-daemon --version > "$WORK_DIR/gradle-version.txt" 2>/dev/null
    EASIPTV_NDK_VERSION="$NDK_VERSION" \
    EASIPTV_CMAKE_VERSION="$CMAKE_VERSION" \
    EASIPTV_ANDROID_API="$ANDROID_API" \
    EASIPTV_ABIS="$ABIS" \
    EASIPTV_SOURCE_ROOT="$ROOT" \
    EASIPTV_NDK_ROOT="$NDK_DIR" \
        "$MEDIA_DIR/gradlew" -p "$MEDIA_DIR" --no-daemon --no-configuration-cache --console=plain \
            -Dorg.gradle.java.home="$JAVA_HOME" \
            -I "$ROOT/gradle/easiptv-decoder.init.gradle" \
            :lib-decoder-ffmpeg:assembleRelease > "$WORK_DIR/gradle.log" 2>&1 \
        || { tail -n 60 "$WORK_DIR/gradle.log" >&2; fail "Gradle build failed (see build/gradle.log)"; }
    local built_aar
    built_aar="$(find "$MEDIA_DIR/libraries/decoder_ffmpeg/buildout/outputs/aar" -name '*-release.aar' | head -n 1)"
    [[ -s "$built_aar" ]] || fail "no release AAR produced"
    cp "$built_aar" "$DIST_DIR/$AAR_NAME"
}

# Checks every libffmpegJNI.so in the AAR: one per ABI, 16 KiB LOAD alignment
# on 64-bit ABIs and a 16 KiB-safe RELRO (scripts/check-relro.sh).
verify_native_libraries() {
    local extracted="$WORK_DIR/aar"
    rm -rf "$extracted" && mkdir -p "$extracted"
    python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
        "$DIST_DIR/$AAR_NAME" "$extracted"
    local abi library alignments
    : > "$WORK_DIR/elf-alignment.txt"
    for abi in "${ABI_LIST[@]}"; do
        library="$extracted/jni/$abi/libffmpegJNI.so"
        [[ -s "$library" ]] || fail "AAR has no jni/$abi/libffmpegJNI.so"
        alignments="$("$TOOLCHAIN_BIN/llvm-readelf" -lW "$library" | awk '$1 == "LOAD" { print $NF }' | sort -u | tr '\n' ' ')"
        printf '%s LOAD alignment: %s\n' "$abi" "$alignments" >> "$WORK_DIR/elf-alignment.txt"
        if [[ "$abi" == arm64-v8a || "$abi" == x86_64 ]] && [[ "$alignments" != "0x4000 " ]]; then
            fail "$abi/libffmpegJNI.so is not 16 KiB aligned ($alignments)"
        fi
    done
    local library_count
    library_count="$(find "$extracted/jni" -name '*.so' | wc -l)"
    [[ "$library_count" == "${#ABI_LIST[@]}" ]] || fail "expected ${#ABI_LIST[@]} native libraries, found $library_count"
    READELF="$TOOLCHAIN_BIN/llvm-readelf" bash "$ROOT/scripts/check-relro.sh" "$extracted" > "$WORK_DIR/relro.txt" \
        || { cat "$WORK_DIR/relro.txt" >&2; fail "RELRO check failed"; }
}

write_source_archives() {
    # git archive is deterministic for a commit; gzip -n drops the timestamp.
    git -C "$FFMPEG_SUBMODULE_DIR" archive --format=tar --prefix="ffmpeg-$FFMPEG_TAG/" HEAD \
        | gzip -n -9 > "$DIST_DIR/ffmpeg-$FFMPEG_TAG-source.tar.gz"
    git -C "$MEDIA_DIR" archive --format=tar --prefix="media-$MEDIA3_TAG/" HEAD libraries/decoder_ffmpeg \
        | gzip -n -9 > "$DIST_DIR/media3-decoder_ffmpeg-$MEDIA3_TAG-source.tar.gz"
    {
        printf '# Changes to FFmpeg %s (%s)\n' "$FFMPEG_TAG" "$FFMPEG_COMMIT"
        git -C "$FFMPEG_SUBMODULE_DIR" diff HEAD
        printf '# Changes to androidx/media %s (%s)\n' "$MEDIA3_TAG" "$MEDIA3_COMMIT"
        git -C "$MEDIA_DIR" diff HEAD
    } > "$DIST_DIR/changes.diff"
}

write_build_notes() {
    local abi gradle_version gradle_jvm
    gradle_version="$(awk '$1 == "Gradle" { print $2; exit }' "$WORK_DIR/gradle-version.txt")"
    gradle_jvm="$("$JAVA_HOME/bin/java" -version 2>&1 | head -n 2 | tr '\n' ' ')"
    {
        printf '# EasIPTV FFmpeg audio decoder — %s\n\n' "$RELEASE_TAG"
        printf 'This software uses libraries from the FFmpeg project under the LGPLv2.1.\n\n'
        printf '| Input | Value |\n|---|---|\n'
        printf '| EasIPTV Player | %s |\n' "$APP_VERSION"
        printf '| androidx/media | %s (`%s`) |\n' "$MEDIA3_TAG" "$MEDIA3_COMMIT"
        printf '| FFmpeg | %s (`%s`) |\n' "$FFMPEG_TAG" "$FFMPEG_COMMIT"
        printf '| FFmpeg license | LGPL version 2.1 or later (`CONFIG_GPL 0`, `CONFIG_NONFREE 0`, `CONFIG_VERSION3 0`) |\n'
        printf '| Android NDK | %s |\n' "$NDK_VERSION"
        printf '| CMake | %s |\n' "$CMAKE_VERSION"
        printf '| Gradle (Media3 wrapper) | %s |\n' "$gradle_version"
        printf '| Gradle JVM | %s |\n' "$gradle_jvm"
        printf '| Minimum API of native code | %s |\n' "$ANDROID_API"
        printf '| ABIs | %s |\n' "$ABIS"
        printf '| Decoders | %s |\n\n' "$DECODERS"
        printf '## FFmpeg configure lines\n\nRun inside the FFmpeg source tree with the NDK `toolchains/llvm/prebuilt/linux-x86_64/bin` first in `PATH`.\n\n'
        for abi in "${ABI_LIST[@]}"; do
            printf '### %s\n\n```\n%s\n```\n\n' "$abi" "$(cat "$WORK_DIR/configure-line-$abi.txt")"
        done
        printf '## JNI wrapper\n\nMedia3 `libraries/decoder_ffmpeg` built unmodified with `:lib-decoder-ffmpeg:assembleRelease` and `gradle/easiptv-decoder.init.gradle` (NDK, CMake, minSdk, ABIs and `-ffile-prefix-map`).\n\n'
        printf '## Native libraries\n\n```\n%s\n```\n\n```\n%s\n```\n\n' "$(cat "$WORK_DIR/elf-alignment.txt")" "$(cat "$WORK_DIR/relro.txt")"
        printf '## Relinking (LGPL-2.1 section 6)\n\n`libffmpegJNI.so` links FFmpeg statically. To relink it with a modified FFmpeg, replace `external/ffmpeg` (or the tree from `ffmpeg-%s-source.tar.gz`) and run `./build-decoder.sh`; the complete sources of the JNI wrapper are in `media3-decoder_ffmpeg-%s-source.tar.gz`.\n' "$FFMPEG_TAG" "$MEDIA3_TAG"
    } > "$DIST_DIR/BUILD.md"
}

write_checksums() {
    (
        cd "$DIST_DIR"
        find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
    )
}

main() {
    require_pinned_submodule "$MEDIA_DIR" "$MEDIA3_COMMIT"
    require_pinned_submodule "$FFMPEG_SUBMODULE_DIR" "$FFMPEG_COMMIT"
    rm -rf "$WORK_DIR" "$DIST_DIR"
    mkdir -p "$WORK_DIR" "$DIST_DIR"
    write_source_archives
    mkdir -p "$FFMPEG_BUILD_DIR"
    tar -xzf "$DIST_DIR/ffmpeg-$FFMPEG_TAG-source.tar.gz" -C "$FFMPEG_BUILD_DIR" --strip-components=1
    local abi
    for abi in "${ABI_LIST[@]}"; do
        build_ffmpeg_for "$abi"
    done
    build_aar
    verify_native_libraries
    write_build_notes
    write_checksums
    echo "== Done: $DIST_DIR"
    cat "$DIST_DIR/SHA256SUMS"
}

main "$@"
