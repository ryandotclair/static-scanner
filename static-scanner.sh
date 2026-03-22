#!/bin/bash
set -euo pipefail

_PRE_NUTANIX_USER="${NUTANIX_USER-}"
_PRE_NUTANIX_PASSWORD="${NUTANIX_PASSWORD-}"
_PRE_NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1" >&2; }
success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
warning() { echo -e "${YELLOW}WARNING:${NC} $1" >&2; }
VERBOSE=false
info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}INFO:${NC} $1" >&2
    fi
}
# High-level progress (stderr, only with -v); separate from per-request API dumps.
stage() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}==>${NC} $1" >&2
    fi
}

usage() {
    cat << EOF
Usage: $0 -s <subnet_name>

Produce a static-IP usage report for one targeted subnet.

  -s, --subnet-name <name>   Subnet name (e.g. vlan402) — required

Prism Central credentials are required and can be set in the following ways (in order of precedence):

  A) Export before running (highest precedence — not overwritten by env.vars):
       export NUTANIX_ENDPOINT=https://<pc-ip>:9440
       export NUTANIX_USER=<user>
       export NUTANIX_PASSWORD='<password>'

  B) File called "env.vars" next to this script with above variables configured (sourced automatically if present).

  C) Command line flags: 
    --pc <url>
    --user <name>
    --password <password>


  -v, --verbose              Main stages on stderr; also full API request/response bodies
  -h, --help                 This help

Also requires: jq, perl (for static-range math), curl.

EOF
    exit 1
}

FILTER_SUBNET_NAME=""
OPT_PC=""
OPT_USER=""
OPT_PASS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--subnet-name)
            [ -z "${2:-}" ] && { error "-s requires a value"; usage; }
            FILTER_SUBNET_NAME="$2"
            shift 2
            ;;
        --pc)
            [ -z "${2:-}" ] && { error "--pc requires a value"; usage; }
            OPT_PC="$2"
            shift 2
            ;;
        --user)
            [ -z "${2:-}" ] && { error "--user requires a value"; usage; }
            OPT_USER="$2"
            shift 2
            ;;
        --password)
            [ -z "${2:-}" ] && { error "--password requires a value"; usage; }
            OPT_PASS="$2"
            shift 2
            ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$FILTER_SUBNET_NAME" ]; then
    error "Subnet name is required (use -s or --subnet-name)."
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_VARS_FILE="${SCRIPT_DIR}/env.vars"
if [ -f "$ENV_VARS_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_VARS_FILE"
fi

# Pre-exported env wins over env.vars
[ -n "$_PRE_NUTANIX_USER" ] && NUTANIX_USER="$_PRE_NUTANIX_USER"
[ -n "$_PRE_NUTANIX_PASSWORD" ] && NUTANIX_PASSWORD="$_PRE_NUTANIX_PASSWORD"
[ -n "$_PRE_NUTANIX_ENDPOINT" ] && NUTANIX_ENDPOINT="$_PRE_NUTANIX_ENDPOINT"

# CLI overrides everything
[ -n "$OPT_PC" ] && NUTANIX_ENDPOINT="$OPT_PC"
[ -n "$OPT_USER" ] && NUTANIX_USER="$OPT_USER"
[ -n "$OPT_PASS" ] && NUTANIX_PASSWORD="$OPT_PASS"

CRED_ERR=""
[ -z "${NUTANIX_ENDPOINT:-}" ] && CRED_ERR="${CRED_ERR} NUTANIX_ENDPOINT is empty (export it, use env.vars, or --pc)."$'\n'
[ -z "${NUTANIX_USER:-}" ] && CRED_ERR="${CRED_ERR} NUTANIX_USER is empty (export it, use env.vars, or --user)."$'\n'
[ -z "${NUTANIX_PASSWORD:-}" ] && CRED_ERR="${CRED_ERR} NUTANIX_PASSWORD is empty (export it, use env.vars, or --password)."$'\n'
if [ -n "$CRED_ERR" ]; then
    error "Missing Prism Central credentials:"
    printf '%s' "$CRED_ERR" >&2
    exit 1
fi

command -v jq &>/dev/null || { error "jq is required"; exit 1; }

BASE_URL="${NUTANIX_ENDPOINT%/}"
case "$BASE_URL" in
  http://*|https://*) ;;
  *) BASE_URL="https://${BASE_URL}" ;;
esac

stage "Credentials resolved; target PC: ${BASE_URL}"

BASIC_AUTH=$(echo -n "${NUTANIX_USER}:${NUTANIX_PASSWORD}" | base64)

SUBNET_LIST_PAGE_LIMIT=100
VNICS_PAGE_LIMIT=100

make_api_request() {
    local METHOD="${1:?}"
    local ENDPOINT="${2:?}"
    local DATA="${3:-}"
    if [ "$VERBOSE" = true ]; then
        info "API ${METHOD} ${ENDPOINT}"
    fi
    local -a curlArgs=(
        -k -sS -w $'\n%{http_code}' --request "$METHOD" --url "$ENDPOINT"
        --header 'Accept: application/json' --header "Authorization: Basic ${BASIC_AUTH}" --insecure
    )
    [ -n "$DATA" ] && curlArgs+=(--header 'Content-Type: application/json' --data "$DATA")
    local raw
    raw="$(curl "${curlArgs[@]}")"
    if [ "$VERBOSE" = true ]; then
        local _c _p
        _c=$(printf '%s\n' "$raw" | tail -n1)
        _p=$(printf '%s\n' "$raw" | sed '$d')
        echo "========== API ${METHOD} ${ENDPOINT} (HTTP ${_c}) ==========" >&2
        printf '%s\n' "$_p" >&2
        echo "========== end ==========" >&2
    fi
    printf '%s\n' "$raw"
}

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'ip-used-check')
VM_IDS_FILE="${TMP_DIR}/vm_ids"
SUBNET_BODY_FILE="${TMP_DIR}/subnet_v4.json"
STATIC_ROWS_FILE="${TMP_DIR}/static_rows"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

: > "$VM_IDS_FILE"
: > "$STATIC_ROWS_FILE"

# --- Resolve subnet extId by name (paginated v4.2 list) ---
stage "Resolve subnet extId by name (v4.2 GET /config/subnets, paginated)"
SUBNET_LIST_PAGE=0
FILTER_SUBNET_UUID=""
while true; do
    EP="${BASE_URL}/api/networking/v4.2/config/subnets?\$page=${SUBNET_LIST_PAGE}&\$limit=${SUBNET_LIST_PAGE_LIMIT}"
    RESP=$(make_api_request "GET" "$EP")
    CODE=$(printf '%s\n' "$RESP" | tail -n1)
    BODY=$(printf '%s\n' "$RESP" | sed '$d')
    if [ "$CODE" != "200" ]; then
        error "Subnet list failed HTTP ${CODE}"
        printf '%s\n' "$BODY" >&2
        exit 1
    fi
    FILTER_SUBNET_UUID=$(printf '%s\n' "$BODY" | jq -r --arg n "$FILTER_SUBNET_NAME" '
        .data[]? | select(.name == $n) | .extId' 2>/dev/null | head -n1)
    if [ -n "$FILTER_SUBNET_UUID" ] && [ "$FILTER_SUBNET_UUID" != "null" ]; then
        break
    fi
    PN=$(printf '%s\n' "$BODY" | jq '(.data // []) | length' 2>/dev/null || echo "0")
    [ "$PN" -eq 0 ] && break
    TOT=$(printf '%s\n' "$BODY" | jq -r '.metadata.totalAvailableResults // empty' 2>/dev/null || true)
    if [ -n "$TOT" ] && [ "$TOT" -gt 0 ] 2>/dev/null; then
        F=$((SUBNET_LIST_PAGE * SUBNET_LIST_PAGE_LIMIT + PN))
        [ "$F" -ge "$TOT" ] && break
    elif [ "$PN" -lt "$SUBNET_LIST_PAGE_LIMIT" ]; then
        break
    fi
    SUBNET_LIST_PAGE=$((SUBNET_LIST_PAGE + 1))
done

if [ -z "$FILTER_SUBNET_UUID" ] || [ "$FILTER_SUBNET_UUID" = "null" ]; then
    error "Subnet not found: \"${FILTER_SUBNET_NAME}\""
    exit 1
fi
stage "Subnet found: extId=${FILTER_SUBNET_UUID}"

# --- Subnet v4 GET (CIDR + DHCP pool for report header) ---
stage "GET subnet config (CIDR, DHCP pool) for report header"
SUB_GET="${BASE_URL}/api/networking/v4.2/config/subnets/${FILTER_SUBNET_UUID}"
SRESP=$(make_api_request "GET" "$SUB_GET")
SCODE=$(printf '%s\n' "$SRESP" | tail -n1)
SBODY=$(printf '%s\n' "$SRESP" | sed '$d')
if [ "$SCODE" != "200" ]; then
    error "Subnet GET failed HTTP ${SCODE}"
    exit 1
fi
printf '%s\n' "$SBODY" > "$SUBNET_BODY_FILE"

SUBNET_CIDR=$(jq -r '
  .data.ipConfig[0].ipv4.ipSubnet
  | if . then "\(.ip.value)/\(.prefixLength)" else empty end
' "$SUBNET_BODY_FILE" 2>/dev/null)
[ -z "$SUBNET_CIDR" ] || [ "$SUBNET_CIDR" = "null" ] && SUBNET_CIDR="(unknown)"

DHCP_START=$(jq -r '.data.ipConfig[0].ipv4.poolList[0].startIp.value // empty' "$SUBNET_BODY_FILE" 2>/dev/null)
DHCP_END=$(jq -r '.data.ipConfig[0].ipv4.poolList[0].endIp.value // empty' "$SUBNET_BODY_FILE" 2>/dev/null)
if [ -n "$DHCP_START" ] && [ -n "$DHCP_END" ]; then
    DHCP_POOL_TXT="${DHCP_START}-${DHCP_END}"
else
    DHCP_POOL_TXT="(no pool in API response)"
fi

# Static carve-out: usable host addresses in subnet CIDR excluding DHCP pool [start,end].
# Uses perl (ships with macOS and most Linux; no extra install). Pure bash CIDR math is brittle
# (signed shifts / ~). Alternative: python3 — not required if perl exists.
STATIC_RANGE_TXT=""
if command -v perl &>/dev/null && [[ "$SUBNET_CIDR" == *"/"* ]] && [ -n "$DHCP_START" ] && [ -n "$DHCP_END" ]; then
    STATIC_RANGE_TXT=$(perl -e '
use strict;
use warnings;
use Socket qw(inet_aton inet_ntoa);

sub ip32 {
    my $b = inet_aton(shift) or return undef;
    unpack("N", $b);
}
sub str {
    inet_ntoa(pack("N", $_[0] & 0xFFFFFFFF));
}

@ARGV == 3 or exit 1;
my ($cidr, $ds, $de) = @ARGV;
my ($as, $pl) = split m{/}, $cidr, 2;
defined $pl && $pl =~ /^\d+$/ or exit 1;
my $ip = ip32($as) // exit 1;
my $nb = 32 - $pl;
my $size = 1 << $nb;
my $wildcard = $size - 1;
my $net = $ip & (0xFFFFFFFF ^ $wildcard);
my $bc  = $net + $size - 1;
my $first = $net + 1;
my $last  = $bc - 1;
if ( $first > $last ) {
    print("(no usable host range for this prefix)\n");
    exit 0;
}
my $plo = ip32($ds) // exit 1;
my $phi = ip32($de) // exit 1;
( $plo, $phi ) = ( $phi, $plo ) if $plo > $phi;
my @h;
for my $x ( $first .. $last ) {
    push @h, $x if $x < $plo || $x > $phi;
}
unless (@h) {
    print("(none — all host addresses fall inside DHCP pool)\n");
    exit 0;
}
my @iv = ( [ $h[0], $h[0] ] );
for my $x ( @h[ 1 .. $#h ] ) {
    if ( $x == $iv[-1][1] + 1 ) { $iv[-1][1] = $x; }
    else { push @iv, [ $x, $x ]; }
}
print join( ", ",
    map { $_->[0] == $_->[1] ? str( $_->[0] ) : str( $_->[0] ) . "-" . str( $_->[1] ) }
    @iv ),
  "\n";
' "$SUBNET_CIDR" "$DHCP_START" "$DHCP_END" 2>/dev/null) || STATIC_RANGE_TXT=""
fi
if [ -z "$STATIC_RANGE_TXT" ]; then
    STATIC_RANGE_TXT="(install perl for auto static-range line, or use subnet range + DHCP pool below)"
fi
stage "Static carve-out (hosts in CIDR minus DHCP pool) computed"

# --- VM UUIDs: v4.2 /vnics only (paginated) ---
stage "List vNICs on subnet → collect unique VM extIds (paginated)"
vpage=0
while true; do
    VEP="${BASE_URL}/api/networking/v4.2/config/subnets/${FILTER_SUBNET_UUID}/vnics?\$page=${vpage}&\$limit=${VNICS_PAGE_LIMIT}"
    VR=$(make_api_request "GET" "$VEP")
    vc=$(printf '%s\n' "$VR" | tail -n1)
    vb=$(printf '%s\n' "$VR" | sed '$d')
    if [ "$vc" != "200" ]; then
        warning "vNICs GET failed HTTP ${vc}"
        break
    fi
    printf '%s\n' "$vb" | jq -r '.data[]?.vmReference // empty' 2>/dev/null >> "$VM_IDS_FILE"
    vn=$(printf '%s\n' "$vb" | jq '(.data // []) | length' 2>/dev/null || echo "0")
    [ "$vn" -eq 0 ] && break
    vtot=$(printf '%s\n' "$vb" | jq -r '.metadata.totalAvailableResults // empty' 2>/dev/null || true)
    if [ -n "$vtot" ] && [ "$vtot" -gt 0 ] 2>/dev/null; then
        vf=$((vpage * VNICS_PAGE_LIMIT + vn))
        [ "$vf" -ge "$vtot" ] && break
    elif [ "$vn" -lt "$VNICS_PAGE_LIMIT" ]; then
        break
    fi
    vpage=$((vpage + 1))
done

awk 'NF' "$VM_IDS_FILE" | sort -u > "${TMP_DIR}/vm_ids.u" && mv "${TMP_DIR}/vm_ids.u" "$VM_IDS_FILE"

VM_COUNT=$(wc -l < "$VM_IDS_FILE" | tr -d '[:space:]')
[ -z "$VM_COUNT" ] && VM_COUNT=0
stage "Unique VMs attached to subnet: ${VM_COUNT}"

if [ "$VM_COUNT" -eq 0 ]; then
    echo "subnet: ${FILTER_SUBNET_NAME}"
    echo "subnet range: ${SUBNET_CIDR}"
    echo "DHCP pool: ${DHCP_POOL_TXT}"
    echo "static range: ${STATIC_RANGE_TXT}"
    echo "Used Static IPs:"
    echo "  (no VMs returned for this subnet)"
    success "Report complete"
    exit 0
fi

stage "Per-VM: GET v4.2 AHV VM config; learnedIpAddresses on NICs for this subnet"

# --- Per VM: v4.2 VMM AHV config; learnedIpAddresses on NICs for this subnet extId ---
while IFS= read -r VM_UUID; do
    [ -z "$VM_UUID" ] && continue
    VM_EP="${BASE_URL}/api/vmm/v4.2/ahv/config/vms/${VM_UUID}"
    VR=$(make_api_request "GET" "$VM_EP")
    VC=$(printf '%s\n' "$VR" | tail -n1)
    VB=$(printf '%s\n' "$VR" | sed '$d')
    if [ "$VC" != "200" ]; then
        warning "VM GET v4 ${VM_UUID} failed HTTP ${VC}, skipping."
        continue
    fi

    VM_NAME=$(printf '%s\n' "$VB" | jq -r '.data.name // "Unknown"' 2>/dev/null)

    # Subnet match on nicNetworkInfo and networkInfo (both may be present); static = learnedIpAddresses[].value
    IPS=$(printf '%s\n' "$VB" | jq -r --arg su "$FILTER_SUBNET_UUID" '
        [
          .data.nics[]?
          | select(
              ((.nicNetworkInfo.subnet.extId // "") == $su)
              or ((.networkInfo.subnet.extId // "") == $su)
            )
          | (
              (.nicNetworkInfo.ipv4Info.learnedIpAddresses // [])
              + (.networkInfo.ipv4Info.learnedIpAddresses // [])
            )[]
          | .value?
          | select(. != null and . != "")
        ]
        | unique
        | join(",")
    ' 2>/dev/null)

    if [ -n "$IPS" ] && [ "$IPS" != "null" ]; then
        echo "${VM_NAME}|${IPS}" >> "$STATIC_ROWS_FILE"
    fi
done < "$VM_IDS_FILE"

# --- Report (stdout) ---
stage "Write report to stdout"
echo "subnet: ${FILTER_SUBNET_NAME}"
echo "subnet range: ${SUBNET_CIDR}"
echo "DHCP pool: ${DHCP_POOL_TXT}"
echo "static range: ${STATIC_RANGE_TXT}"
echo "Used Static IPs:"
if [ ! -s "$STATIC_ROWS_FILE" ]; then
    echo "  (no static IPs discovered on this subnet)"
else
    sort -t'|' -k1,1 "$STATIC_ROWS_FILE" | while IFS='|' read -r rname rips; do
        echo "  |_${rname}: ${rips}"
    done
fi

echo ""
success "Report complete"
