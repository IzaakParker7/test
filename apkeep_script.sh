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
  [--config PATH] [--no-config] [--print-config]
  [--verify none|zip|apk-sig|all]
  [--checksums PATH] [--allow-unsigned]
USAGE
}

json_escape(){
  local str="$1" out="" c
  local len=${#str}
  local i
  for ((i=0; i<len; i++)); do
    c=${str:i:1}
    case $c in
      $'\\') out+='\\\\' ;;
      '"') out+='\\"' ;;
      $'\n') out+='\\n' ;;
      $'\t') out+='\\t' ;;
      $'\r') ;; 
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

declare -A EXIT_CODE_MAP=(
  [NO_BASE_APK]=21
  [BASE_INCOMPATIBLE]=22
  [ABI_MISMATCH]=23
  [MINSDK_TOO_HIGH]=24
  [DENSITY_SPLIT_MISSING]=25
  [ADB_INSTALL_FAILED]=26
  [DOWNLOAD_FAILED]=27
  [UNPACK_FAILED]=28
  [CHECKSUM_OR_SIG_FAILED]=29
  [NO_APKS_FOUND]=30
)

fail_with(){
  local category="$1"
  local detail="$2"
  local version="${3:-$CURRENT_VERSION_LABEL}"
  local attempt=${4:-$ATTEMPT_COUNT}
  local code=${EXIT_CODE_MAP[$category]:-1}
  local human="[X] $category: $detail"
  echo "$human"
  local esc_detail; esc_detail=$(json_escape "$detail")
  local esc_pkg; esc_pkg=$(json_escape "$PKG_NAME")
  local esc_version; esc_version=$(json_escape "$version")
  printf '{"ok":false,"category":"%s","detail":"%s","package":"%s","version":"%s","attempt":%d}\n' \
    "$category" "$esc_detail" "$esc_pkg" "$esc_version" "$attempt"
  exit "$code"
}

LAST_FAILURE_CATEGORY=""
LAST_FAILURE_DETAIL=""
LAST_FAILURE_VERSION=""
LAST_FAILURE_ATTEMPT=0

declare -A CHECKSUM_MAP=()

record_failure(){
  LAST_FAILURE_CATEGORY="$1"
  LAST_FAILURE_DETAIL="$2"
  LAST_FAILURE_VERSION="$CURRENT_VERSION_LABEL"
  LAST_FAILURE_ATTEMPT="$ATTEMPT_COUNT"
}

fail_with_last(){
  local category="${LAST_FAILURE_CATEGORY:-NO_APKS_FOUND}"
  local detail="${LAST_FAILURE_DETAIL:-No compatible APKs found after attempts.}"
  local version="${LAST_FAILURE_VERSION:-$CURRENT_VERSION_LABEL}"
  local attempt="${LAST_FAILURE_ATTEMPT:-$ATTEMPT_COUNT}"
  fail_with "$category" "$detail" "$version" "$attempt"
}

init_defaults(){
  SOURCE_SITE="apk-pure"
  ABI_CSV="armeabi-v7a,armeabi"
  MIN_SDK=28
  MAX_TRIES=10
  DRY=0
  VERBOSE=0
  VERIFY_MODE="none"
  CHECKSUMS_FILE=""
  ALLOW_UNSIGNED=0
  DEVICE_SERIAL=""
  NO_CONFIG=0
  PRINT_CONFIG=0
  CONFIG_PATHS=()
  ABI_ORIGIN="builtin"
  MINSDK_ORIGIN="builtin"
  CHECKSUMS_ENABLED=0
  ATTEMPT_COUNT=0
  CURRENT_VERSION_LABEL=""
}

normalize_bool(){
  local value="${1,,}"
  case "$value" in
    1|true|yes|on) echo 1 ;;
    0|false|no|off) echo 0 ;;
    *) return 1 ;;
  esac
}

apply_config_key(){
  local key="$1"
  local value="$2"
  case "$key" in
    source)
      SOURCE_SITE="$value"
      ;;
    abi)
      ABI_CSV="${value//[[:space:]]/}"
      ABI_ORIGIN="config"
      ;;
    min_sdk)
      if [[ $value =~ ^[0-9]+$ ]]; then
        MIN_SDK="$value"
        MINSDK_ORIGIN="config"
      fi
      ;;
    max_tries)
      if [[ $value =~ ^[0-9]+$ && $value -gt 0 ]]; then
        MAX_TRIES="$value"
      fi
      ;;
    dry)
      local bool
      if bool=$(normalize_bool "$value"); then
        DRY="$bool"
      fi
      ;;
    verbose)
      local bool
      if bool=$(normalize_bool "$value"); then
        VERBOSE="$bool"
      fi
      ;;
    device_serial)
      DEVICE_SERIAL="$value"
      ;;
    verify)
      case "$value" in
        none|zip|apk-sig|all)
          VERIFY_MODE="$value"
          ;;
      esac
      ;;
    checksums_file)
      CHECKSUMS_FILE="$value"
      [[ -n $CHECKSUMS_FILE ]] && CHECKSUMS_ENABLED=1
      ;;
    allow_unsigned)
      local bool
      if bool=$(normalize_bool "$value"); then
        ALLOW_UNSIGNED="$bool"
      fi
      ;;
  esac
}

trim_line(){
  local line="$1"
  line="${line%%$'\r'}"
  line="${line%%#*}"
  line="${line#${line%%[!$' \t']*}}"
  line="${line%${line##*[!$' \t']}}"
  echo "$line"
}

load_config_file(){
  local path="$1"
  [[ -f $path ]] || return 0
  while IFS= read -r raw_line || [[ -n $raw_line ]]; do
    local line
    line=$(trim_line "$raw_line")
    [[ -z $line ]] && continue
    [[ $line == *=* ]] || continue
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key,,}"
    key="${key// /}"
    value="${value#${value%%[!$' \t']*}}"
    value="${value%${value##*[!$' \t']}}"
    apply_config_key "$key" "$value"
  done < "$path"
}

load_configs(){
  (( NO_CONFIG )) && return
  local -a order=("/etc/apkeep/.apkeep.conf")
  local home_conf="$HOME/.config/apkeep/.apkeep.conf"
  order+=("$home_conf" "./.apkeep.conf")
  local path
  for path in "${order[@]}"; do
    [[ -f $path ]] || continue
    log_verbose "Loading config: $path"
    load_config_file "$path"
  done
  local cfg
  for cfg in "${CONFIG_PATHS[@]}"; do
    if [[ ! -f $cfg ]]; then
      echo "[-] Config file not found: $cfg" >&2
      exit 1
    fi
    log_verbose "Loading config: $cfg"
    load_config_file "$cfg"
  done
}

CLI_SOURCE_SET=0
CLI_SOURCE_VALUE=""
CLI_ABI_SET=0
CLI_ABI_VALUE=""
CLI_MINSDK_SET=0
CLI_MINSDK_VALUE=0
CLI_MAXTRIES_SET=0
CLI_MAXTRIES_VALUE=0
CLI_DRY_SET=0
CLI_VERBOSE_SET=0
CLI_VERIFY_SET=0
CLI_VERIFY_VALUE=""
CLI_CHECKSUMS_SET=0
CLI_CHECKSUMS_VALUE=""
CLI_ALLOW_UNSIGNED_SET=0

apply_cli_overrides(){
  if (( CLI_SOURCE_SET )); then
    SOURCE_SITE="$CLI_SOURCE_VALUE"
  fi
  if (( CLI_ABI_SET )); then
    ABI_CSV="${CLI_ABI_VALUE//[[:space:]]/}"
    ABI_ORIGIN="cli"
  fi
  if (( CLI_MINSDK_SET )); then
    MIN_SDK="$CLI_MINSDK_VALUE"
    MINSDK_ORIGIN="cli"
  fi
  if (( CLI_MAXTRIES_SET )); then
    MAX_TRIES="$CLI_MAXTRIES_VALUE"
  fi
  if (( CLI_DRY_SET )); then
    DRY=1
  fi
  if (( CLI_VERBOSE_SET )); then
    VERBOSE=1
  fi
  if (( CLI_VERIFY_SET )); then
    VERIFY_MODE="$CLI_VERIFY_VALUE"
  fi
  if (( CLI_CHECKSUMS_SET )); then
    CHECKSUMS_FILE="$CLI_CHECKSUMS_VALUE"
    CHECKSUMS_ENABLED=1
  fi
  if (( CLI_ALLOW_UNSIGNED_SET )); then
    ALLOW_UNSIGNED=1
  fi
}

resolve_verify_mode(){
  case "$VERIFY_MODE" in
    apk-sig|all)
      if ! command -v apksigner >/dev/null 2>&1; then
        if [[ $VERIFY_MODE == "apk-sig" ]]; then
          log "[!] apksigner not found; falling back to zip verification."
          VERIFY_MODE="zip"
        else
          log "[!] apksigner not found; performing zip verification only."
          VERIFY_MODE="zip"
        fi
      fi
      ;;
  esac
}

ADB_SERIAL_ARGS=()

update_adb_serial(){
  ADB_SERIAL_ARGS=()
  if [[ -n $DEVICE_SERIAL ]]; then
    ADB_SERIAL_ARGS=(-s "$DEVICE_SERIAL")
  fi
}

trim_cr(){
  local value="$1"
  value="${value%$'\r'}"
  echo "$value"
}

detect_device_defaults(){
  command -v adb >/dev/null 2>&1 || return
  if [[ $ABI_ORIGIN == "builtin" ]]; then
    local abilist=""
    local output
    if output=$(adb "${ADB_SERIAL_ARGS[@]}" shell getprop ro.product.cpu.abilist 2>/dev/null); then
      output=$(trim_cr "$output")
      output="${output//[$'\r\n']/}"
      output="${output// /}"
      if [[ -n $output ]]; then
        abilist="$output"
      fi
    fi
    if [[ -z $abilist ]]; then
      local abi1 abi2
      abi1=$(adb "${ADB_SERIAL_ARGS[@]}" shell getprop ro.product.cpu.abi 2>/dev/null || true)
      abi2=$(adb "${ADB_SERIAL_ARGS[@]}" shell getprop ro.product.cpu.abi2 2>/dev/null || true)
      abi1=$(trim_cr "$abi1")
      abi2=$(trim_cr "$abi2")
      abi1="${abi1//[$'\r\n']/}"
      abi2="${abi2//[$'\r\n']/}"
      local -a list=()
      [[ -n $abi1 ]] && list+=("$abi1")
      [[ -n $abi2 && $abi2 != $abi1 ]] && list+=("$abi2")
      if ((${#list[@]})); then
        abilist=$(IFS=','; echo "${list[*]}")
      fi
    fi
    if [[ -n $abilist ]]; then
      ABI_CSV="$abilist"
      ABI_ORIGIN="device"
      log_verbose "Detected device ABIs: $ABI_CSV"
    fi
  fi
  if [[ $MINSDK_ORIGIN == "builtin" ]]; then
    local sdk
    if sdk=$(adb "${ADB_SERIAL_ARGS[@]}" shell getprop ro.build.version.sdk 2>/dev/null); then
      sdk=$(trim_cr "$sdk")
      sdk="${sdk//[$'\r\n']/}"
      if [[ $sdk =~ ^[0-9]+$ ]]; then
        MIN_SDK="$sdk"
        MINSDK_ORIGIN="device"
        log_verbose "Detected device minSdk: $MIN_SDK"
      fi
    fi
  fi
}

finalize_abi_list(){
  local IFS=','
  read -r -a TARGET_ABIS <<< "$ABI_CSV"
  local -a cleaned=()
  local abi
  for abi in "${TARGET_ABIS[@]}"; do
    abi="${abi//[[:space:]]/}"
    [[ -z $abi ]] && continue
    cleaned+=("$abi")
  done
  TARGET_ABIS=("${cleaned[@]}")
  if ((${#TARGET_ABIS[@]} == 0)); then
    echo "[-] ABI list cannot be empty." >&2
    exit 1
  fi
  ABI_CSV=$(IFS=','; echo "${TARGET_ABIS[*]}")
}

bool_to_string(){
  (( $1 )) && echo true || echo false
}

print_effective_config(){
  cat <<EOF
source=$SOURCE_SITE
abi=$ABI_CSV
min_sdk=$MIN_SDK
max_tries=$MAX_TRIES
dry=$(bool_to_string "$DRY")
verbose=$(bool_to_string "$VERBOSE")
device_serial=$DEVICE_SERIAL
verify=$VERIFY_MODE
checksums_file=$CHECKSUMS_FILE
allow_unsigned=$(bool_to_string "$ALLOW_UNSIGNED")
EOF
}

parse_args(){
  init_defaults
  PKG_SPEC=""
  OUT_DIR=""
  CLI_SOURCE_SET=0
  CLI_SOURCE_VALUE=""
  CLI_ABI_SET=0
  CLI_ABI_VALUE=""
  CLI_MINSDK_SET=0
  CLI_MINSDK_VALUE=0
  CLI_MAXTRIES_SET=0
  CLI_MAXTRIES_VALUE=0
  CLI_DRY_SET=0
  CLI_VERBOSE_SET=0
  CLI_VERIFY_SET=0
  CLI_VERIFY_VALUE=""
  CLI_CHECKSUMS_SET=0
  CLI_CHECKSUMS_VALUE=""
  CLI_ALLOW_UNSIGNED_SET=0

  local positional=0
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --source)
        [[ $# -ge 2 ]] || { echo "[-] --source requires a value." >&2; exit 1; }
        CLI_SOURCE_SET=1
        CLI_SOURCE_VALUE="$2"
        shift 2
        continue
        ;;
      --abi)
        [[ $# -ge 2 ]] || { echo "[-] --abi requires a value." >&2; exit 1; }
        CLI_ABI_SET=1
        CLI_ABI_VALUE="$2"
        shift 2
        continue
        ;;
      --min-sdk)
        [[ $# -ge 2 ]] || { echo "[-] --min-sdk requires a value." >&2; exit 1; }
        [[ $2 =~ ^[0-9]+$ ]] || { echo "[-] --min-sdk expects an integer." >&2; exit 1; }
        CLI_MINSDK_SET=1
        CLI_MINSDK_VALUE="$2"
        shift 2
        continue
        ;;
      --max-tries)
        [[ $# -ge 2 ]] || { echo "[-] --max-tries requires a value." >&2; exit 1; }
        [[ $2 =~ ^[0-9]+$ && $2 -gt 0 ]] || { echo "[-] --max-tries expects a positive integer." >&2; exit 1; }
        CLI_MAXTRIES_SET=1
        CLI_MAXTRIES_VALUE="$2"
        shift 2
        continue
        ;;
      --dry)
        CLI_DRY_SET=1
        shift
        continue
        ;;
      --verbose)
        CLI_VERBOSE_SET=1
        shift
        continue
        ;;
      --config)
        [[ $# -ge 2 ]] || { echo "[-] --config requires a value." >&2; exit 1; }
        CONFIG_PATHS+=("$2")
        shift 2
        continue
        ;;
      --no-config)
        NO_CONFIG=1
        shift
        continue
        ;;
      --print-config)
        PRINT_CONFIG=1
        shift
        continue
        ;;
      --verify)
        [[ $# -ge 2 ]] || { echo "[-] --verify requires a value." >&2; exit 1; }
        case "$2" in
          none|zip|apk-sig|all)
            CLI_VERIFY_SET=1
            CLI_VERIFY_VALUE="$2"
            ;;
          *)
            echo "[-] Unknown verify mode: $2" >&2
            exit 1
            ;;
        esac
        shift 2
        continue
        ;;
      --checksums)
        [[ $# -ge 2 ]] || { echo "[-] --checksums requires a value." >&2; exit 1; }
        CLI_CHECKSUMS_SET=1
        CLI_CHECKSUMS_VALUE="$2"
        shift 2
        continue
        ;;
      --allow-unsigned)
        CLI_ALLOW_UNSIGNED_SET=1
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

  if [[ -z $PKG_SPEC && PRINT_CONFIG -eq 0 ]]; then
    echo "[-] Package spec is required." >&2
    usage >&2
    exit 1
  fi

  load_configs
  apply_cli_overrides
  resolve_verify_mode
  update_adb_serial
  detect_device_defaults
  finalize_abi_list

  if (( PRINT_CONFIG )); then
    print_effective_config
    exit 0
  fi

  if [[ -z $PKG_SPEC ]]; then
    echo "[-] Package spec is required." >&2
    exit 1
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

check_dependencies(){
  need apkeep
  need adb
  need unzip
  need zipinfo
}

list_versions(){
  local output
  if ! output=$(apkeep -a "$PKG_NAME" -d "$SOURCE_SITE" -l); then
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
  ((${#FOUND_APKS[@]} > 0))
}

check_abi(){
  local apk="$1"
  ABI_LAST_LIBS=()
  mapfile -t ABI_LAST_LIBS < <(zipinfo -1 "$apk" | awk -F'/' '$1 == "lib" && NF >= 2 {print $2}' | sort -u)
  if ((${#ABI_LAST_LIBS[@]} == 0)); then
    ABI_STATUS="ABI OK (none)"
    return 0
  fi
  local libs_join
  libs_join=$(IFS=','; echo "${ABI_LAST_LIBS[*]}")
  local target
  for target in "${TARGET_ABIS[@]}"; do
    local lib
    for lib in "${ABI_LAST_LIBS[@]}"; do
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
  MINSDK_STATUS="minSdk skip"
  MINSDK_LAST_VALUE=""
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
    MINSDK_LAST_VALUE="$sdk_value"
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
  ABI_LIBS_PRESENT=0
  ABI_MATCH_FOUND=0
  MINSDK_FAIL_COUNT=0
  MINSDK_PASS_COUNT=0
  MINSDK_HIGHEST=0
  declare -A LIB_SEEN=()
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
    if ((${#ABI_LAST_LIBS[@]} > 0)); then
      ABI_LIBS_PRESENT=1
      local lib
      for lib in "${ABI_LAST_LIBS[@]}"; do
        LIB_SEEN[$lib]=1
      done
      if (( abi_ok == 0 )); then
        ABI_MATCH_FOUND=1
      fi
    fi
    check_minsdk "$apk"
    local sdk_ok=$?
    if [[ -n $MINSDK_LAST_VALUE ]]; then
      if (( sdk_ok == 0 )); then
        MINSDK_PASS_COUNT=$((MINSDK_PASS_COUNT + 1))
      else
        MINSDK_FAIL_COUNT=$((MINSDK_FAIL_COUNT + 1))
        (( MINSDK_LAST_VALUE > MINSDK_HIGHEST )) && MINSDK_HIGHEST=$MINSDK_LAST_VALUE
      fi
    else
      MINSDK_PASS_COUNT=$((MINSDK_PASS_COUNT + 1))
    fi
    printf '  - %s : %s; %s\n' "$(basename "$apk")" "$ABI_STATUS" "$MINSDK_STATUS"
    if (( abi_ok == 0 && sdk_ok == 0 )); then
      COMPATIBLE_APKS+=("$apk")
      if (( is_base )); then
        BASE_OK=1
      fi
    fi
  done
  if (( base_identified == 0 )); then
    BASE_STATUS="Unable to identify a base APK."
  elif (( BASE_OK == 0 )); then
    BASE_STATUS="Base APK $(basename "$BASE_APK") failed compatibility checks."
  fi
  ALL_LIBS=()
  local key
  for key in "${!LIB_SEEN[@]}"; do
    ALL_LIBS+=("$key")
  done
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

load_checksums_file(){
  CHECKSUM_MAP=()
  [[ -n $CHECKSUMS_FILE ]] || return 0
  if [[ ! -f $CHECKSUMS_FILE ]]; then
    INTEGRITY_ERROR="Checksums file not found: $CHECKSUMS_FILE"
    return 1
  fi
  while IFS= read -r raw_line || [[ -n $raw_line ]]; do
    local line
    line=$(trim_line "$raw_line")
    [[ -z $line ]] && continue
    local sha="${line%%[[:space:]]*}"
    local rest="${line#"$sha"}"
    rest="${rest#${rest%%[!$' \t']*}}"
    [[ -z $sha || -z $rest ]] && continue
    CHECKSUM_MAP["$rest"]="$sha"
  done < "$CHECKSUMS_FILE"
  return 0
}

verify_checksums(){
  (( CHECKSUMS_ENABLED )) || return 0
  if ! load_checksums_file; then
    return 1
  fi
  local file
  for file in "$@"; do
    local rel base expected=""
    rel="${file#$WORK_DIR/}"
    base=$(basename "$file")
    if [[ -n ${CHECKSUM_MAP[$file]:-} ]]; then
      expected="${CHECKSUM_MAP[$file]}"
    elif [[ -n ${CHECKSUM_MAP[$rel]:-} ]]; then
      expected="${CHECKSUM_MAP[$rel]}"
    elif [[ -n ${CHECKSUM_MAP[$base]:-} ]]; then
      expected="${CHECKSUM_MAP[$base]}"
    fi
    [[ -z $expected ]] && continue
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ ${actual,,} != ${expected,,} ]]; then
      INTEGRITY_ERROR="Checksum mismatch for $(basename "$file") (expected $expected, got $actual)"
      return 1
    fi
  done
  return 0
}

verify_zip_integrity(){
  local file
  for file in "$@"; do
    if ! unzip -tqq "$file" >/dev/null; then
      INTEGRITY_ERROR="Zip integrity failed for $(basename "$file")"
      return 1
    fi
  done
  return 0
}

verify_apk_signatures(){
  local file
  for file in "$@"; do
    local output
    if output=$(apksigner verify --print-certs "$file" 2>&1); then
      continue
    fi
    if (( ALLOW_UNSIGNED )) && grep -qi 'not signed' <<<"$output"; then
      log "[!] $(basename "$file") is unsigned; continuing due to --allow-unsigned."
      continue
    fi
    if (( ALLOW_UNSIGNED )) && grep -qi 'no jar signatures' <<<"$output"; then
      log "[!] $(basename "$file") lacks signatures; continuing due to --allow-unsigned."
      continue
    fi
    INTEGRITY_ERROR="Signature verification failed for $(basename "$file"): ${output//$'\n'/ }"
    return 1
  done
  return 0
}

perform_integrity_checks(){
  if [[ $VERIFY_MODE == "none" && $CHECKSUMS_ENABLED -eq 0 ]]; then
    return 0
  fi
  local -a files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$WORK_DIR" -type f \( -name '*.apk' -o -name '*.xapk' \) -print0)
  if [[ $VERIFY_MODE == "zip" || $VERIFY_MODE == "all" ]]; then
    if ! verify_zip_integrity "${files[@]}"; then
      return 1
    fi
  fi
  if [[ $VERIFY_MODE == "apk-sig" || $VERIFY_MODE == "all" ]]; then
    local -a apks=()
    local f
    for f in "${files[@]}"; do
      [[ $f == *.apk ]] && apks+=("$f")
    done
    if ((${#apks[@]})) && ! verify_apk_signatures "${apks[@]}"; then
      return 1
    fi
  fi
  if ! verify_checksums "${files[@]}"; then
    return 1
  fi
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
  local -a cmd=(adb)
  if ((${#ADB_SERIAL_ARGS[@]})); then
    cmd+=("${ADB_SERIAL_ARGS[@]}")
  fi
  cmd+=(install-multiple)
  local output
  if output=$("${cmd[@]}" "${COMPATIBLE_APKS[@]}" 2>&1); then
    [[ -n $output ]] && echo "$output"
    echo "[✓] Installed $PKG_NAME@$label"
    return 0
  fi
  [[ -n $output ]] && echo "$output"
  local detail=${output//$'\n'/ }
  if grep -qi 'missing split' <<<"$output"; then
    fail_with DENSITY_SPLIT_MISSING "$detail" "$label" "$ATTEMPT_COUNT"
  elif grep -qi 'no matching abis' <<<"$output"; then
    fail_with ABI_MISMATCH "$detail" "$label" "$ATTEMPT_COUNT"
  elif grep -qi 'older sdk' <<<"$output"; then
    fail_with MINSDK_TOO_HIGH "$detail" "$label" "$ATTEMPT_COUNT"
  else
    fail_with ADB_INSTALL_FAILED "$detail" "$label" "$ATTEMPT_COUNT"
  fi
}

run_attempt(){
  local version="$1"
  ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
  CURRENT_VERSION_LABEL="${version:-latest}"
  WORK_DIR="$OUT_DIR/attempt_$ATTEMPT_COUNT"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  log "[*] Trying version $CURRENT_VERSION_LABEL (attempt $ATTEMPT_COUNT/$MAX_TRIES)"

  if ! download_version "$version"; then
    log "[-] Download failed for version $CURRENT_VERSION_LABEL." >&2
    record_failure DOWNLOAD_FAILED "Download failed for version $CURRENT_VERSION_LABEL."
    return 1
  fi
  if ! unpack_xapks; then
    log "[-] Failed to unpack XAPK contents for version $CURRENT_VERSION_LABEL." >&2
    record_failure UNPACK_FAILED "Failed to unpack XAPK contents."
    return 1
  fi
  if ! collect_apks; then
    log "[-] No APK files found after download. Try 'apkeep -a $PKG_NAME -d $SOURCE_SITE -l' to inspect available builds." >&2
    record_failure NO_APKS_FOUND "No APK files found after download."
    return 1
  fi
  INTEGRITY_ERROR=""
  if ! perform_integrity_checks; then
    record_failure CHECKSUM_OR_SIG_FAILED "${INTEGRITY_ERROR:-Integrity verification failed}"
    log "[-] Integrity verification failed: ${INTEGRITY_ERROR:-unknown}" >&2
    return 1
  fi
  compatible_set
  if [[ -n $BASE_STATUS ]]; then
    echo "[-] $BASE_STATUS" >&2
  fi
  if [[ -z $BASE_APK ]]; then
    record_failure NO_BASE_APK "Unable to identify a base APK."
    log "[-] Version $CURRENT_VERSION_LABEL incompatible, trying next…"
    return 1
  fi
  if (( BASE_OK == 0 )); then
    record_failure BASE_INCOMPATIBLE "Base APK $(basename "$BASE_APK") failed compatibility checks."
    log "[-] Version $CURRENT_VERSION_LABEL incompatible, trying next…"
    return 1
  fi
  if ((${#COMPATIBLE_APKS[@]} == 0)); then
    if (( ABI_LIBS_PRESENT && ABI_MATCH_FOUND == 0 )); then
      local libs_join
      libs_join=$(IFS=','; echo "${ALL_LIBS[*]}")
      record_failure ABI_MISMATCH "No APK libraries matched target ABI(s) (${ABI_CSV}). Available: $libs_join"
    elif (( MINSDK_FAIL_COUNT > 0 && MINSDK_PASS_COUNT == 0 )); then
      record_failure MINSDK_TOO_HIGH "All APKs require minSdk $MINSDK_HIGHEST (> $MIN_SDK)."
    else
      record_failure NO_APKS_FOUND "No compatible APK splits passed validation."
    fi
    log "[-] Version $CURRENT_VERSION_LABEL incompatible, trying next…"
    return 1
  fi
  if install_apks "$CURRENT_VERSION_LABEL"; then
    local esc_version; esc_version=$(json_escape "$CURRENT_VERSION_LABEL")
    local esc_pkg; esc_pkg=$(json_escape "$PKG_NAME")
    printf '{"ok":true,"package":"%s","version":"%s","attempt":%d}\n' "$esc_pkg" "$esc_version" "$ATTEMPT_COUNT"
    return 0
  fi
  return 1
}

try_versions_loop(){
  ATTEMPT_COUNT=0
  LAST_FAILURE_CATEGORY=""
  LAST_FAILURE_DETAIL=""
  LAST_FAILURE_VERSION=""
  LAST_FAILURE_ATTEMPT=0

  if [[ -n $LOCKED_VERSION ]]; then
    if run_attempt "$LOCKED_VERSION"; then
      return
    fi
    fail_with_last
  fi

  if run_attempt ""; then
    return
  fi
  local -A tried=([latest]=1)
  if (( ATTEMPT_COUNT >= MAX_TRIES )); then
    fail_with_last
  fi
  mapfile -t AVAILABLE_VERSIONS < <(list_versions) || {
    record_failure DOWNLOAD_FAILED "Unable to list available versions for fallback."
    fail_with_last
  }
  if ((${#AVAILABLE_VERSIONS[@]} == 0)); then
    record_failure NO_APKS_FOUND "No versions available for fallback."
    fail_with_last
  fi
  local version
  for version in "${AVAILABLE_VERSIONS[@]}"; do
    if (( ATTEMPT_COUNT >= MAX_TRIES )); then
      break
    fi
    if [[ -n ${tried[$version]+x} ]]; then
      continue
    fi
    tried[$version]=1
    if run_attempt "$version"; then
      return
    fi
  done
  fail_with_last
}

main(){
  parse_args "$@"
  split_pkg_spec
  setup_dirs
  trap cleanup EXIT
  check_dependencies
  if command -v aapt >/dev/null 2>&1; then
    HAVE_AAPT=1
  else
    HAVE_AAPT=0
  fi
  try_versions_loop
}

main "$@"
