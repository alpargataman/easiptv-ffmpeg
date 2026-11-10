#!/usr/bin/env bash
# Checks that the GNU_RELRO segment of every 64-bit native library (arm64-v8a,
# x86_64) is safe on 16 KB page devices (issue #540).
#
# The dynamic linker makes RELRO read-only page by page, rounding its start
# down and its end up to the device page size. On a 16 KiB device that rounded
# range must not contain writable data outside RELRO, or that data turns
# read-only and the library crashes. A RELRO whose end satisfies
# (VirtAddr + MemSiz) % 0x4000 == 0 passes trivially; otherwise it passes only
# if no writable PT_LOAD byte outside RELRO shares its 16 KiB pages.
#
# Usage: scripts/ci/check-relro.sh <app.apk|app.aab|dir>
# readelf: $READELF if set, else the newest NDK llvm-readelf under
# $ANDROID_HOME/ndk, else llvm-readelf or readelf from PATH.
# Exit codes: 0 all pass, 1 some library fails, 2 usage or input error.
set -euo pipefail

readonly PAGE_SIZE=$((0x4000))
readonly ABI_LIBRARY_PATTERN='/(arm64-v8a|x86_64)/[^/]+\.so$'
readonly ELF_MAGIC=$'\x7fELF'

fail() {
    echo "check-relro.sh: $*" >&2
    exit 2
}

resolve_readelf() {
    if [[ -n "${READELF:-}" ]]; then
        echo "$READELF"
        return
    fi
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [[ -n "$sdk" && -d "$sdk/ndk" ]]; then
        local ndk_readelf
        ndk_readelf="$(find "$sdk/ndk" -path '*/toolchains/llvm/prebuilt/*/bin/llvm-readelf' | sort -V | tail -n 1)"
        if [[ -n "$ndk_readelf" ]]; then
            echo "$ndk_readelf"
            return
        fi
    fi
    command -v llvm-readelf || command -v readelf || fail "no readelf found: set READELF or install the NDK"
}

# Prints "RELRO <vaddr> <memsz>" and "WLOAD <vaddr> <memsz>" (writable PT_LOAD) lines.
# awk reads all input on purpose: exiting early would SIGPIPE readelf under pipefail.
read_segments() {
    "$READELF_BIN" -lW "$1" | awk '
        $1 == "GNU_RELRO" { print "RELRO", $3, $6 }
        $1 == "LOAD" {
            flags = ""
            for (i = 7; i < NF; i++) flags = flags $i
            if (flags ~ /W/) print "WLOAD", $3, $6
        }'
}

# Prints the verdict for one library; returns 1 when it is not 16 KiB safe.
check_library() {
    local library="$1" name="$2"
    local kind address size relro_start=-1 relro_end=-1
    local -a writable_segments=()
    while read -r kind address size; do
        case "$kind" in
            RELRO) relro_start=$((address)); relro_end=$((address + size)) ;;
            WLOAD) writable_segments+=("$((address)) $((address + size))") ;;
        esac
    done < <(read_segments "$library")

    if (( relro_start < 0 )); then
        printf 'PASS %s (no GNU_RELRO segment)\n' "$name"
        return 0
    fi

    local protected_start=$(( relro_start / PAGE_SIZE * PAGE_SIZE ))
    local protected_end=$(( (relro_end + PAGE_SIZE - 1) / PAGE_SIZE * PAGE_SIZE ))
    local segment segment_start segment_end before_relro_end after_relro_start
    for segment in "${writable_segments[@]}"; do
        read -r segment_start segment_end <<<"$segment"
        # Writable bytes outside RELRO: [segment_start, before_relro_end) and [after_relro_start, segment_end)
        before_relro_end=$(( segment_end < relro_start ? segment_end : relro_start ))
        after_relro_start=$(( segment_start > relro_end ? segment_start : relro_end ))
        if (( (segment_start < before_relro_end && before_relro_end > protected_start) ||
              (after_relro_start < segment_end && after_relro_start < protected_end) )); then
            printf 'FAIL %s (writable segment 0x%x-0x%x shares a 16 KiB page with RELRO 0x%x-0x%x)\n' \
                "$name" "$segment_start" "$segment_end" "$relro_start" "$relro_end"
            return 1
        fi
    done

    if (( relro_end % PAGE_SIZE == 0 )); then
        printf 'PASS %s (RELRO end 0x%x is 16 KiB aligned)\n' "$name" "$relro_end"
    else
        printf 'PASS %s (RELRO end 0x%x unaligned, but its 16 KiB page holds no other writable data)\n' \
            "$name" "$relro_end"
    fi
}

[[ $# -eq 1 ]] || fail "usage: $0 <app.apk|app.aab|dir>"
readonly INPUT="$1"
[[ -e "$INPUT" ]] || fail "input not found: $INPUT"

READELF_BIN="$(resolve_readelf)"
readonly READELF_BIN

if [[ -d "$INPUT" ]]; then
    root="$INPUT"
else
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' EXIT
    # unzip exits 11 when no entry matches; an archive without libraries is reported below
    unzip -qq -o "$INPUT" '*.so' -d "$root" || [[ $? -eq 11 ]] || fail "cannot extract $INPUT"
fi

mapfile -t libraries < <(find "$root" -type f -name '*.so' | grep -E "$ABI_LIBRARY_PATTERN" | sort)
(( ${#libraries[@]} > 0 )) || fail "no arm64-v8a or x86_64 libraries found in $INPUT"

echo "readelf: $READELF_BIN"
checked=0
offenders=()
for library in "${libraries[@]}"; do
    name="${library#"$root"/}"
    # Some dependencies ship non-ELF payloads (e.g. zip archives) under a .so name
    if [[ "$(head -c 4 "$library")" != "$ELF_MAGIC" ]]; then
        printf 'SKIP %s (not an ELF file)\n' "$name"
        continue
    fi
    checked=$((checked + 1))
    check_library "$library" "$name" || offenders+=("$name")
done

printf '%d ELF libraries checked, %d failed\n' "$checked" "${#offenders[@]}"
if (( ${#offenders[@]} > 0 )); then
    echo "Libraries whose GNU_RELRO shares a 16 KiB page with writable data:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    exit 1
fi
