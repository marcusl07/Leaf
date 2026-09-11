#!/usr/bin/env bash
set -uo pipefail

KEEP_CLIPPINGS=0
if [[ "${1:-}" == "--keep-clippings" ]]; then
  KEEP_CLIPPINGS=1
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: scripts/probe_mtp_kindle_native.sh [--keep-clippings]

Builds and runs a one-process libmtp Kindle probe. By default, the probe
summarizes the downloaded My Clippings.txt file and deletes the raw copy.
EOF
  exit 0
elif [[ -n "${1:-}" ]]; then
  echo "Unknown option: $1" >&2
  echo "Usage: scripts/probe_mtp_kindle_native.sh [--keep-clippings]" >&2
  exit 64
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
out_dir="${PWD}/mtp-kindle-native-probe-${timestamp}"
mkdir -p "$out_dir"

log_file="$out_dir/probe.log"

log() {
  printf '%s\n' "$*" | tee -a "$log_file"
}

run_capture() {
  local label="$1"
  local file="$2"
  shift 2

  log ""
  log "== $label =="
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } >"$out_dir/$file" 2>&1
  local status=$?
  log "wrote $file (exit $status)"
  return "$status"
}

find_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi

  for prefix in /opt/homebrew /usr/local; do
    if [[ -x "$prefix/bin/$name" ]]; then
      printf '%s/bin/%s\n' "$prefix" "$name"
      return 0
    fi
  done

  return 1
}

find_prefix() {
  local formula="$1"
  local header="$2"

  if command -v brew >/dev/null 2>&1; then
    local brewed
    brewed="$(brew --prefix "$formula" 2>/dev/null || true)"
    if [[ -n "$brewed" && -e "$brewed/$header" ]]; then
      printf '%s\n' "$brewed"
      return 0
    fi
  fi

  for prefix in /opt/homebrew /usr/local; do
    if [[ -e "$prefix/$header" ]]; then
      printf '%s\n' "$prefix"
      return 0
    fi
  done

  return 1
}

write_system_info() {
  {
    echo "date: $(date)"
    echo "sw_vers:"
    sw_vers
    echo "uname: $(uname -a)"
    echo "arch: $(uname -m)"
    echo "shell: ${SHELL:-unknown}"
    echo "pwd: $PWD"
    echo "cc: ${cc:-missing}"
    echo "libmtp_prefix: ${libmtp_prefix:-missing}"
    echo "libusb_prefix: ${libusb_prefix:-missing}"
  } >"$out_dir/system.txt" 2>&1
}

write_readme() {
  cat >"$out_dir/README.txt" <<EOF
Kindle MTP native one-session probe

Send this whole folder back:
$out_dir

What this test checks:
- A small native helper links directly against libmtp/libusb.
- The helper opens one MTP device session.
- The same process lists files immediately after opening the device.
- The same process finds documents/My Clippings.txt and downloads it.
- The script writes byte count, SHA-256, clipping separator count, and metadata-line count.
- The raw downloaded clippings file is deleted by default.

To keep the downloaded My Clippings.txt for private manual inspection, rerun with:
./scripts/probe_mtp_kindle_native.sh --keep-clippings
EOF
}

write_summary() {
  local clippings_file="$1"
  local helper_output="$2"
  {
    grep -E '^(raw_device_count|raw_vendor|raw_product|raw_vendor_id|raw_product_id|manufacturer|model|serial|friendly_name|storage|selected_file_|downloaded_bytes|separator_count|metadata_line_count|result):' "$helper_output" || true
    echo "sha256: $(shasum -a 256 "$clippings_file" | awk '{print $1}')"
  } >"$out_dir/clippings-summary.txt"
}

log "Kindle MTP native one-session probe"
log "Output directory: $out_dir"
log ""
log "Before continuing:"
log "- Close Amazon USB File Manager, OpenMTP, Calibre, Android File Transfer, and any other file-transfer app."
log "- Unplug the Kindle."
log "- Fully restart the Kindle."
log "- Wake or unlock the Kindle if the screen asks."
log "- Plug the Kindle back in with USB."
log "- Wait about 5 seconds after plugging it in."
log ""
log "This probe downloads only My Clippings.txt if it can find it."
log "By default, it deletes the downloaded file after writing size/hash/counts."
log ""
printf 'Press Return after the Kindle has been restarted and freshly plugged in... '
read -r _

cc="$(find_tool cc || find_tool clang || true)"
libmtp_prefix="$(find_prefix libmtp include/libmtp.h || true)"
libusb_prefix="$(find_prefix libusb include/libusb-1.0/libusb.h || true)"

write_system_info
write_readme

missing=0
if [[ -z "$cc" ]]; then
  log "Missing compiler: cc/clang"
  missing=1
fi
if [[ -z "$libmtp_prefix" ]]; then
  log "Missing libmtp headers/library."
  log "Install them with: brew install libmtp"
  missing=1
fi
if [[ -z "$libusb_prefix" ]]; then
  log "Missing libusb headers/library."
  log "Install them with: brew install libusb"
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  log ""
  log "Result: native MTP probe prerequisites are missing."
  log "Send back this folder if you want me to inspect the setup state: $out_dir"
  exit 2
fi

helper="$out_dir/probe_mtp_kindle_native"
source_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/probe_mtp_kindle_native.c"
clippings_file="$out_dir/My Clippings.txt"
helper_output="$out_dir/native-helper.txt"

log ""
log "Using:"
log "cc: $cc"
log "libmtp: $libmtp_prefix"
log "libusb: $libusb_prefix"

run_capture "compile native helper" "compile.txt" \
  "$cc" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$libmtp_prefix/include" \
  -I"$libusb_prefix/include/libusb-1.0" \
  -L"$libmtp_prefix/lib" \
  -L"$libusb_prefix/lib" \
  -Wl,-rpath,"$libmtp_prefix/lib" \
  -Wl,-rpath,"$libusb_prefix/lib" \
  "$source_file" \
  -lmtp \
  -lusb-1.0 \
  -o "$helper" || {
    log ""
    log "Result: native helper compile failed."
    log "Send back the probe directory: $out_dir"
    exit 3
  }

run_capture "native one-session probe" "native-helper.txt" "$helper" "$clippings_file"
probe_status=$?
if [[ "$probe_status" -ne 0 ]]; then
  log ""
  log "Result: native helper could not complete the one-session download."
  log "Send back the probe directory: $out_dir"
  exit "$probe_status"
fi

if [[ ! -s "$clippings_file" ]]; then
  log ""
  log "Result: native helper reported success, but no non-empty clippings file was created."
  log "Send back the probe directory: $out_dir"
  exit 4
fi

write_summary "$clippings_file" "$helper_output"

if [[ "$KEEP_CLIPPINGS" -eq 0 ]]; then
  rm -f "$clippings_file"
  log "Deleted downloaded My Clippings.txt after writing clippings-summary.txt."
else
  log "Kept downloaded My Clippings.txt because --keep-clippings was passed."
fi

log ""
log "Result: SUCCESS. Native one-session MTP can download My Clippings.txt from this Kindle."
log "Send back the probe directory: $out_dir"
