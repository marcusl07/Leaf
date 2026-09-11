#!/usr/bin/env bash
set -uo pipefail

timestamp="$(date +%Y%m%d-%H%M%S)"
out_dir="${PWD}/mtp-kindle-comparison-${timestamp}"
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

prepare_kindle() {
  local phase="$1"
  log ""
  log "$phase"
  log "- Fully quit Amazon USB File Manager, OpenMTP, Calibre, Android File Transfer, and similar apps."
  log "- Unplug the Kindle."
  log "- Fully restart the Kindle."
  log "- Wake or unlock it if needed."
  log "- Plug it back in and wait about 5 seconds."
  printf 'Press Return when ready... '
  read -r _
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
    echo "mtp_files: ${mtp_files:-missing}"
    echo "libmtp_prefix: ${libmtp_prefix:-missing}"
    echo "libusb_prefix: ${libusb_prefix:-missing}"
  } >"$out_dir/system.txt" 2>&1
}

log "Kindle MTP controlled comparison"
log "Output directory: $out_dir"
log ""
log "This runs the standard mtp-files tool and Leaf's helper after separate fresh Kindle restarts."
log "Diagnostics include USB and MTP protocol events, but not raw file contents."

cc="$(find_tool cc || find_tool clang || true)"
mtp_files="$(find_tool mtp-files || true)"
libmtp_prefix="$(find_prefix libmtp include/libmtp.h || true)"
libusb_prefix="$(find_prefix libusb include/libusb-1.0/libusb.h || true)"
write_system_info

if [[ -z "$cc" || -z "$mtp_files" || -z "$libmtp_prefix" || -z "$libusb_prefix" ]]; then
  log ""
  log "Result: required compiler or libmtp/libusb tools are missing."
  log "Install the MTP dependencies with: brew install libmtp"
  log "Send back this folder if installation still does not resolve it: $out_dir"
  exit 2
fi

helper="$out_dir/probe_mtp_kindle_native"
source_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/probe_mtp_kindle_native.c"
clippings_file="$out_dir/My Clippings.txt"

run_capture "compile Leaf helper" "compile.txt" \
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
    log "Result: Leaf helper did not compile."
    exit 3
  }

prepare_kindle "Phase 1 of 2: prepare a fresh connection for the standard mtp-files tool."
run_capture "standard mtp-files with PTP and USB diagnostics" "mtp-files-debug.txt" \
  env LIBMTP_DEBUG=5 "$mtp_files"
mtp_files_status=$?

prepare_kindle "Phase 2 of 2: prepare a second fresh connection for Leaf's native helper."
run_capture "Leaf helper with PTP and USB diagnostics" "leaf-helper-debug.txt" \
  env LIBMTP_DEBUG=5 "$helper" "$clippings_file"
helper_status=$?

{
  echo "mtp_files_exit: $mtp_files_status"
  echo "mtp_files_found_clippings: $(grep -qi 'My Clippings\.txt' "$out_dir/mtp-files-debug.txt" && echo yes || echo no)"
  echo "leaf_helper_exit: $helper_status"
  if [[ -s "$clippings_file" ]]; then
    echo "leaf_helper_downloaded_bytes: $(wc -c <"$clippings_file" | tr -d ' ')"
    echo "leaf_helper_separator_count: $(grep -c '^==========[[:space:]]*$' "$clippings_file" || true)"
    echo "leaf_helper_metadata_line_count: $(grep -Ec '^-[[:space:]]+Your (Highlight|Note|Bookmark)' "$clippings_file" || true)"
    echo "leaf_helper_sha256: $(shasum -a 256 "$clippings_file" | awk '{print $1}')"
  else
    echo "leaf_helper_downloaded_bytes: 0"
  fi
} >"$out_dir/comparison-summary.txt"

if [[ -e "$clippings_file" ]]; then
  rm -f "$clippings_file"
  log "Deleted the downloaded My Clippings.txt after writing the privacy-safe summary."
fi

log ""
log "Comparison complete. Send back this whole folder:"
log "$out_dir"
