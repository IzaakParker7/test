#!/usr/bin/env bash
# apkeep_script.sh - Download and install compatible APKs via apkeep with auto-fallback.
#
# Examples:
#   ./apkeep_script.sh com.instagram.android
#   ./apkeep_script.sh com.instagram.android@1.2024.321 ./ig
#   ./apkeep_script.sh com.app . --abi armeabi-v7a,armeabi --min-sdk 26 --verbose
#   ./apkeep_script.sh com.soundcloud.android . --max-tries 5
#   ./apkeep_script.sh com.whatsapp . --dry

set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[-] Need '$1' installed."; exit 127; }; }

log(){ echo "$@"; }
log_verbose(){ (( VERBOSE )) && echo "[v] $*"; }

usage(){
  cat <<USAGE
Usage: apkeep_script.sh <package[@version]> [output_dir]
  [--source apk-pure|apk-mirror]
  [--abi list,of,abis]
  [--min-sdk N]
  [--max-tries N]
  [--dry] [--verbose]
USAGE
}

parse_args(){
  PKG_SPEC=""
  OUT_DIR=""
  SOURCE_SITE="apk-pure"
  local abi_csv="armeabi-v7a,armeabi"
  MIN_SDK=28
  MAX_TRIES=10
  DRY=0
  VERBOSE=0

  local positional=0
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --source)
        [[ $# -ge 2 ]] || { echo "[-] --source requires a value." >&2; exit 1; }
        SOURCE_SITE="$2"
        shift 2
        continue
        ;;
      --abi)
        [[ $# -ge 2 ]] || { echo "[-] --abi requires a value." >&2; exit 1; }
        abi_csv="$2"
        shift 2
        continue
        ;;
      --min-sdk)
        [[ $# -ge 2 ]] || { echo "[-] --min-sdk requires a value." >&2; exit 1; }
        MIN_SDK="$2"
        [[ $MIN_SDK =~ ^[0-9]+$ ]] || { echo "[-] --min-sdk expects an integer." >&2; exit 1; }
        shift 2
        continue
        ;;
      --max-tries)
        [[ $# -ge 2 ]] || { echo "[-] --max-tries requires a value." >&2; exit 1; }
        MAX_TRIES="$2"
        [[ $MAX_TRIES =~ ^[0-9]+$ && $MAX_TRIES -gt 0 ]] || { echo "[-] --max-tries expects a positive integer." >&2; exit 1; }
        shift 2
        continue
        ;;
      --dry)
        DRY=1
        shift
        continue
        ;;
      --verbose)
        VERBOSE=1
        shift
        continue
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "[-] Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if (( positional == 0 )); then
          PKG_SPEC="$1"
        elif (( positional == 1 )); then
          OUT_DIR="$1"
        else
          echo "[-] Too many positional arguments." >&2
          exit 1
        fi
        positional=$((positional + 1))
        shift
        continue
        ;;
    esac
  done

  if [[ -z $PKG_SPEC ]]; then
    echo "[-] Package spec is required." >&2
    usage >&2
    exit 1
  fi

  local IFS=','
  read -r -a TARGET_ABIS <<< "$abi_csv"
  if ((${#TARGET_ABIS[@]} == 0)); then
    echo "[-] --abi list cannot be empty." >&2
    exit 1
  fi
}

setup_dirs(){
  TEMP_DIR=""
  if [[ -n $OUT_DIR ]]; then
    mkdir -p "$OUT_DIR"
    log "[+] Using output dir: $OUT_DIR"
  else
    TEMP_DIR=$(mktemp -d -t apkeep_XXXX)
    OUT_DIR="$TEMP_DIR"
    log "[+] Working directory: $OUT_DIR"
  fi
}

cleanup(){
  if [[ -n ${TEMP_DIR:-} && -d ${TEMP_DIR:-} ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

split_pkg_spec(){
  if [[ $PKG_SPEC == *@* ]]; then
    PKG_NAME="${PKG_SPEC%@*}"
    LOCKED_VERSION="${PKG_SPEC#*@}"
  else
    PKG_NAME="$PKG_SPEC"
    LOCKED_VERSION=""
  fi
  if [[ -z $PKG_NAME ]]; then
    echo "[-] Package name cannot be empty." >&2
    exit 1
  fi
}

check_dependencies(){
  need apkeep
  need adb
  need unzip
  need zipinfo
  if command -v aapt >/dev/null 2>&1; then
    HAVE_AAPT=1
  else
    HAVE_AAPT=0
  fi
}

list_versions(){
  local output
  if ! output=$(apkeep -a "$PKG_NAME" -d "$SOURCE_SITE" -l); then
    echo "[-] Failed to list versions from $SOURCE_SITE." >&2
    return 1
  fi
  local line token
  local -a versions=()
  local -A seen=()
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z $line ]] && continue
    [[ $line =~ ^[[:space:]]*(Version|VERSIONS?) ]] && continue
    line=${line//|/ }
    local IFS=$' \t'
    for token in $line; do
      token="${token#,}"
      token="${token%,}"
      token="${token#(}"
      token="${token%)}"
      token="${token%:}"
      if [[ $token =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
        if [[ -z ${seen[$token]+x} ]]; then
          versions+=("$token")
          seen[$token]=1
        fi
      fi
    done
  done <<< "$output"
  printf '%s\n' "${versions[@]}"
}

unpack_xapks(){
  local xapk dest
  while IFS= read -r -d '' xapk; do
    dest="${xapk%.xapk}_unpacked"
    rm -rf "$dest"
    mkdir -p "$dest"
    if unzip -q "$xapk" -d "$dest"; then
      log_verbose "Unpacked $(basename "$xapk")"
    else
      echo "[-] Failed to unpack $(basename "$xapk")." >&2
      return 1
    fi
  done < <(find "$WORK_DIR" -maxdepth 1 -type f -name '*.xapk' -print0)
  return 0
}

collect_apks(){
  FOUND_APKS=()
  while IFS= read -r -d '' apk; do
    FOUND_APKS+=("$apk")
  done < <(find "$WORK_DIR" -type f -name '*.apk' -print0)
  if ((${#FOUND_APKS[@]} == 0)); then
    return 1
  fi
  return 0
}

check_abi(){
  local apk="$1"
  local -a libs=()
  mapfile -t libs < <(zipinfo -1 "$apk" | awk -F'/' '$1 == "lib" && NF >= 2 {print $2}' | sort -u)
  if ((${#libs[@]} == 0)); then
    ABI_STATUS="ABI OK (none)"
    return 0
  fi
  local libs_join
  libs_join=$(IFS=','; echo "${libs[*]}")
  local target
  for target in "${TARGET_ABIS[@]}"; do
    local lib
    for lib in "${libs[@]}"; do
      if [[ $lib == "$target" ]]; then
        ABI_STATUS="ABI OK (libs: $libs_join)"
        return 0
      fi
    done
  done
  ABI_STATUS="ABI NO (libs: $libs_join)"
  return 1
}

check_minsdk(){
  local apk="$1"
  if (( ! HAVE_AAPT )); then
    MINSDK_STATUS="minSdk skip (aapt missing)"
    return 0
  fi
  local badging
  if ! badging=$(aapt dump badging "$apk" 2>/dev/null); then
    MINSDK_STATUS="minSdk unknown"
    return 0
  fi
  local sdk_line
  sdk_line=$(grep -o "sdkVersion:'[^']*'" <<< "$badging" | head -n 1 || true)
  if [[ -z $sdk_line ]]; then
    MINSDK_STATUS="minSdk unknown"
    return 0
  fi
  local sdk_value="${sdk_line#sdkVersion:'}"
  sdk_value="${sdk_value%'}"
  if [[ $sdk_value =~ ^[0-9]+$ ]]; then
    if (( sdk_value <= MIN_SDK )); then
      MINSDK_STATUS="minSdk OK ($sdk_value)"
      return 0
    else
      MINSDK_STATUS="minSdk NO ($sdk_value > $MIN_SDK)"
      return 1
    fi
  else
    MINSDK_STATUS="minSdk unknown ($sdk_value)"
    return 0
  fi
}

is_base_apk(){
  local apk="$1"
  local name
  name=$(basename "$apk")

  if (( HAVE_AAPT )); then
    local badging
    if badging=$(aapt dump badging "$apk" 2>/dev/null); then
      if grep -q " split=" <<<"$badging"; then
        return 1
      fi
      if grep -q " isFeatureSplit=" <<<"$badging"; then
        return 1
      fi
      return 0
    fi
  fi

  if [[ $name == "base.apk" || $name == "$PKG_NAME.apk" ]]; then
    return 0
  fi
  if [[ $name == split_config.* || $name == config.* ]]; then
    return 1
  fi
  if [[ $name == *_config.*.apk ]]; then
    return 1
  fi
  return 0
}

compatible_set(){
  COMPATIBLE_APKS=()
  BASE_STATUS=""
  BASE_APK=""
  BASE_OK=0
  local base_identified=0
  local apk
  for apk in "${FOUND_APKS[@]}"; do
    local is_base=0
    if is_base_apk "$apk"; then
      is_base=1
      base_identified=1
      BASE_APK="$apk"
    fi
    check_abi "$apk"
    local abi_ok=$?
    check_minsdk "$apk"
    local sdk_ok=$?
    printf '  - %s : %s; %s\n' "$(basename "$apk")" "$ABI_STATUS" "$MINSDK_STATUS"
    if (( abi_ok == 0 && sdk_ok == 0 )); then
      COMPATIBLE_APKS+=("$apk")
      if (( is_base )); then
        BASE_OK=1
      fi
    fi
  done
  if (( base_identified == 0 )); then
    BASE_STATUS="[-] Unable to identify a base APK in the downloaded package set."
  elif (( BASE_OK == 0 )); then
    BASE_STATUS="[-] Base APK $(basename "$BASE_APK") failed compatibility checks."
  fi
  return 0
}

download_version(){
  local version="$1"
  local spec="$PKG_NAME"
  if [[ -n $version ]]; then
    spec="$PKG_NAME@$version"
  fi
  log_verbose "Running: apkeep -a $spec -d $SOURCE_SITE $WORK_DIR"
  if ! apkeep -a "$spec" -d "$SOURCE_SITE" "$WORK_DIR"; then
    return 1
  fi
  log "[+] Downloaded $spec"
  return 0
}

install_apks(){
  local label="$1"
  if (( DRY )); then
    printf '[DRY] adb install-multiple'
    local apk
    for apk in "${COMPATIBLE_APKS[@]}"; do
      printf ' %q' "$apk"
    done
    printf '\n'
    echo "[✓] Dry-run would install $PKG_NAME@$label"
    return 0
  fi
  if adb install-multiple "${COMPATIBLE_APKS[@]}"; then
    echo "[✓] Installed $PKG_NAME@$label"
    return 0
  fi
  return 1
}

run_attempt(){
  local version="$1"
  ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
  local label="latest"
  if [[ -n $version ]]; then
    label="$version"
  fi
  WORK_DIR="$OUT_DIR/attempt_$ATTEMPT_COUNT"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  log "[*] Trying version $label (attempt $ATTEMPT_COUNT/$MAX_TRIES)"
  if ! download_version "$version"; then
    echo "[-] Download failed for version $label." >&2
    return 1
  fi
  if ! unpack_xapks; then
    echo "[-] Failed to unpack XAPK contents for version $label." >&2
    return 1
  fi
  if ! collect_apks; then
    echo "[-] No APK files found after download. Try 'apkeep -a $PKG_NAME -d $SOURCE_SITE -l' to inspect available builds." >&2
    exit 2
  fi
  compatible_set
  if [[ -n $BASE_STATUS ]]; then
    echo "$BASE_STATUS" >&2
  fi
  if ((${#COMPATIBLE_APKS[@]} == 0)) || (( BASE_OK == 0 )); then
    echo "[-] Version $label incompatible, trying next…"
    return 1
  fi
  if install_apks "$label"; then
    return 0
  fi
  echo "[-] adb install-multiple failed." >&2
  exit 4
}

try_versions_loop(){
  ATTEMPT_COUNT=0
  declare -A tried=()
  if [[ -n $LOCKED_VERSION ]]; then
    if ! run_attempt "$LOCKED_VERSION"; then
      echo "[-] Specified version $LOCKED_VERSION is not compatible." >&2
      exit 3
    fi
    return
  fi

  if run_attempt ""; then
    return
  fi
  tried[latest]=1
  if (( ATTEMPT_COUNT >= MAX_TRIES )); then
    echo "[-] Reached maximum attempts ($MAX_TRIES)." >&2
    exit 3
  fi

  mapfile -t AVAILABLE_VERSIONS < <(list_versions) || {
    echo "[-] Unable to obtain version list for fallback." >&2
    exit 3
  }
  if ((${#AVAILABLE_VERSIONS[@]} == 0)); then
    echo "[-] No versions available for fallback." >&2
    exit 3
  fi

  local version
  for version in "${AVAILABLE_VERSIONS[@]}"; do
    if [[ -n ${tried[$version]+x} ]]; then
      continue
    fi
    if (( ATTEMPT_COUNT >= MAX_TRIES )); then
      break
    fi
    tried[$version]=1
    if run_attempt "$version"; then
      return
    fi
  done
  echo "[-] No compatible APKs found after $ATTEMPT_COUNT attempts." >&2
  exit 3
}

main(){
  parse_args "$@"
  split_pkg_spec
  setup_dirs
  trap cleanup EXIT
  check_dependencies
  try_versions_loop
}

main "$@"
