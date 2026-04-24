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
# Expected follow-ups (e.g. v4.2 missing, v3 path) — only print with -v.
verbose_warning() {
    if [ "$VERBOSE" = true ]; then
        warning "$1"
    fi
}
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
Usage: $0 -s <subnet_name>   (subnet report — default mode)
   or: $0 --check <A.B.C.D>  (global IP-in-use check; optional -s to limit NICs to one subnet)

Produce a static-IP usage report for one targeted subnet, or check a single IPv4 against VM NICs.

  -s, --subnet-name <name>   Subnet name (e.g. vlan402). Required for report mode. With --check,
                             optional: limits the scan to NICs on that subnet only (faster).

  --check <IPv4>             List any VM whose NIC reports this IP (v3 ip_endpoint_list, any type).
                             Without -s: scans all VMs on Prism Central (any subnet). With -s:
                             only NICs attached to that subnet. Note: the same address can exist on
                             different private subnets; global mode reports every NIC that carries it.

Prism Central credentials are required and can be set in the following ways (in order of precedence):

  A) Command line flags (highest — override env and env.vars):
    --pc <url>
    --user <name>
    --password <password>

  B) Export before running (wins over env.vars; overridden by flags above):
       export NUTANIX_ENDPOINT=https://<pc-ip>:9440
       export NUTANIX_USER=<user>
       export NUTANIX_PASSWORD='<password>'

  C) File called "env.vars" next to this script with above variables configured (sourced automatically if present).


  --k8s                      After the Nutanix VM report, query the current kubectl context
                             (NKP management cluster) for Cluster objects: for each Nutanix
                             workload cluster whose control plane or a node pool uses this
                             subnet name, print API VIP and service LB address range(s).
                             Not allowed with --check.

  -v, --verbose              Main stages on stderr; also full API request/response bodies
  -h, --help                 This help

Also requires: jq, perl (for static-range math), curl. With --k8s: kubectl (pointed at mgmt cluster).
Check mode (--check) uses jq and curl only (no perl).

EOF
    exit 1
}

FILTER_SUBNET_NAME=""
CHECK_IP=""
OPT_PC=""
OPT_USER=""
OPT_PASS=""
INCLUDE_K8S=false

while [ $# -gt 0 ]; do
    case "$1" in
        --check)
            [ -z "${2:-}" ] && { error "--check requires an IPv4 address"; usage; }
            CHECK_IP="$2"
            shift 2
            ;;
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
        --k8s) INCLUDE_K8S=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$CHECK_IP" ] && [ -z "$FILTER_SUBNET_NAME" ]; then
    error "Either -s/--subnet-name (subnet report) or --check <IPv4> is required."
    usage
fi
if [ -n "$CHECK_IP" ]; then
    if ! [[ "$CHECK_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        error "Invalid IPv4 for --check: ${CHECK_IP}"
        usage
    fi
    for _oct in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        if [ "$_oct" -gt 255 ] 2>/dev/null; then
            error "Invalid IPv4 octet in --check: ${CHECK_IP}"
            usage
        fi
    done
fi
if [ -n "$CHECK_IP" ] && [ "$INCLUDE_K8S" = true ]; then
    error "--k8s cannot be used with --check."
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
if [ "$VERBOSE" = true ]; then
    echo "================================================"
    echo "Using..."
    echo "SUBNET_NAME: ${FILTER_SUBNET_NAME:-"(none — check scans all subnets)"}"
    echo "CHECK_IP: ${CHECK_IP:-"(report mode)"}"
    echo "NUTANIX_USER: ${NUTANIX_USER}"
    echo "NUTANIX_PASSWORD: ${NUTANIX_PASSWORD}"
    echo "NUTANIX_ENDPOINT: ${BASE_URL}"
fi

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

# Paginate v3 vms/list; any ip_endpoint_list[].ip matching CHECK_IP (all endpoint types: ASSIGNED, LEARNED, …).
# If FILTER_SUBNET_UUID is set, only NICs whose subnet_reference.uuid matches.
RunCheckIpAcrossVms() {
    local ep="${BASE_URL}/api/nutanix/v3/vms/list"
    local lim=500 off=0 got tot body resp code hitsPath scopeLine
    hitsPath="${TMP_DIR}/ip_check_hits.tsv"
    : > "$hitsPath"

    if [ -n "${FILTER_SUBNET_UUID:-}" ]; then
        scopeLine="Scope: subnet \"${FILTER_SUBNET_NAME}\" only (uuid ${FILTER_SUBNET_UUID}) — NICs on other subnets are ignored."
    else
        scopeLine="Scope: all subnets on this Prism Central — any VM NIC. Note: the same IP address can legitimately appear on different L2 segments; this lists every NIC that reports it."
    fi

    stage "Check ${CHECK_IP} against VM inventory (v3 POST /vms/list)"
    off=0
    while true; do
        body=$(jq -nc --argjson o "$off" --argjson l "$lim" '{kind:"vm",length:$l,offset:$o}')
        resp=$(make_api_request "POST" "$ep" "$body")
        code=$(printf '%s\n' "$resp" | tail -n1)
        body=$(printf '%s\n' "$resp" | sed '$d')
        if [ "$code" != "200" ]; then
            error "v3 vms/list failed HTTP ${code} at offset=${off}"
            exit 1
        fi
        printf '%s\n' "$body" | jq -r --arg ip "$CHECK_IP" --arg su "${FILTER_SUBNET_UUID-}" '
            def subId(n):
                (n.subnet_reference
                 | if . == null then ""
                   elif type == "object" then (.uuid // "")
                   else (. | tostring) end);
            def subnetLabel(n):
                (n.subnet_reference // null) as $sr
                | if $sr == null then "(no subnet ref)"
                  elif ($sr | type) == "object" then
                    (if ($sr.name // "") != "" then "\($sr.name) (uuid=\($sr.uuid // "?"))" else "uuid=\($sr.uuid // "?")" end)
                  else "?"
                  end;
            (.entities // [])[]
            | .metadata.uuid as $uuid
            | (.status.name // .spec.name // $uuid) as $vmname
            | [
                (.status.resources.nic_list // [])[],
                (.spec.resources.nic_list // [])[]
                | select(($su | length) == 0 or (subId(.) == $su))
                | . as $nic
                | ($nic.ip_endpoint_list // [])[]
                | select((.ip // "") == $ip)
                | "\($vmname)\t\(subnetLabel($nic))\t\((.type // "?") | tostring)\t\($uuid)"
              ]
            | .[]
        ' 2>/dev/null >> "$hitsPath" || true

        got=$(printf '%s\n' "$body" | jq '(.entities // []) | length' 2>/dev/null || echo "0")
        tot=$(printf '%s\n' "$body" | jq -r '.metadata.total_matches // empty' 2>/dev/null || true)
        [ "$got" -eq 0 ] && break
        if [ -n "$tot" ] && [ "$tot" -gt 0 ] 2>/dev/null; then
            off=$((off + got))
            [ "$off" -ge "$tot" ] && break
        elif [ "$got" -lt "$lim" ]; then
            break
        else
            off=$((off + got))
        fi
    done

    echo "check: ${CHECK_IP}"
    echo "${scopeLine}"
    if [ ! -s "$hitsPath" ]; then
        echo "Result: Not found in use."
    else
        echo "Result: In Use!"
        sort -u "$hitsPath" | while IFS=$'\t' read -r _vmn _subnet _typ _uuid; do
            echo "  |_ VM: ${_vmn} — subnet: ${_subnet} — endpoint type: ${_typ}"
            if [ "$VERBOSE" = true ]; then
                echo "      (vm uuid: ${_uuid})" >&2
            fi
        done
    fi
}

# Optional: NKP workload clusters whose CP or node pool uses this subnet (kubectl → mgmt cluster).
EmitK8sClustersOnSubnet() {
    local subnetName="${1:?}"
    if [ "$INCLUDE_K8S" != true ]; then
        return 0
    fi
    echo ""
    echo "NKP Cluster(s) on subnet ${subnetName}:"
    if ! command -v kubectl &>/dev/null; then
        warning "kubectl not found; cannot list workload clusters."
        echo "  (skipped)"
        return 0
    fi
    if ! kubectl config current-context &>/dev/null; then
        warning "No current kubectl context; point kubeconfig at the NKP management cluster."
        echo "  (skipped)"
        return 0
    fi
    stage "kubectl get cluster -A (Nutanix provider workloads)"
    local raw
    if ! raw=$(kubectl get cluster -A -o json 2>/dev/null); then
        warning "kubectl get cluster -A -o json failed (needs cluster-api Clusters on the mgmt cluster)."
        echo "  (skipped)"
        return 0
    fi
    local printedAny=false
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local cname cpNames npNames
        cname=$(echo "$item" | jq -r '.metadata.name // empty')
        [ -z "$cname" ] && continue
        cpNames=$(echo "$item" | jq -r '
            [.spec.topology.variables[]?.value.controlPlane.nutanix.machineDetails.subnets[]?.name // empty]
            | unique
            | .[]
        ')
        npNames=$(echo "$item" | jq -r '
            [.spec.topology.workers.machineDeployments[]?.variables.overrides[]?.value.nutanix.machineDetails.subnets[]?.name // empty]
            | unique
            | .[]
        ')
        local cpMatch=false npMatch=false
        echo "$cpNames" | grep -Fxq "$subnetName" && cpMatch=true || true
        echo "$npNames" | grep -Fxq "$subnetName" && npMatch=true || true
        if [ "$cpMatch" != true ] && [ "$npMatch" != true ]; then
            continue
        fi
        printedAny=true
        echo "${cname}"
        if [ "$cpMatch" = true ]; then
            local vip
            vip=$(echo "$item" | jq -r '.spec.controlPlaneEndpoint.host // empty')
            if [ -z "$vip" ]; then
                vip="(unknown)"
            fi
            echo "  |_Control Plane VIP: ${vip}"
        fi
        if [ "$npMatch" = true ]; then
            local lbJoined
            lbJoined=$(echo "$item" | jq -r '
                def ipstr(v):
                    if v == null then ""
                    elif (v|type) == "string" then v
                    elif (v|type) == "object" and (v.value|type) == "string" then v.value
                    elif (v|type) == "object" and (v.value|type) == "number" then (v.value|tostring)
                    else "" end;
                [
                  .spec.topology.variables[]?.value.addons.serviceLoadBalancer.configuration.addressRanges[]?
                  | (ipstr(.start) + "-" + ipstr(.end))
                ]
                | map(select(length > 2 and . != "--"))
                | unique
                | join(", ")
            ')
            if [ -z "$lbJoined" ]; then
                lbJoined="(no service LB address range in cluster spec)"
            fi
            echo "  |_Node Pool VIP(s): ${lbJoined}"
        fi
    done < <(echo "$raw" | jq -c '.items[]? | select(((.metadata.labels["konvoy.d2iq.io/provider"] // "") | ascii_downcase) == "nutanix")')
    if [ "$printedAny" = false ]; then
        echo "  (no Nutanix workload clusters use this subnet for control plane or node pools in the current kubectl context)"
    fi
}

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'ip-used-check')
VM_IDS_FILE="${TMP_DIR}/vm_ids"
SUBNET_BODY_FILE="${TMP_DIR}/subnet_v4.json"
SUBNET_V3_ENTITY_FILE="${TMP_DIR}/subnet_v3_entity.json"
STATIC_ROWS_FILE="${TMP_DIR}/static_rows"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

: > "$VM_IDS_FILE"
: > "$STATIC_ROWS_FILE"

# v42: networking v4.2 list + GET. v3: first-page 404 on subnet list → resolve via v3 subnets/list only.
SUBNET_SOURCE="v42"
FILTER_SUBNET_UUID=""

# Paginated v3 subnet list; writes first entity matching FILTER_SUBNET_NAME to SUBNET_V3_ENTITY_FILE; sets FILTER_SUBNET_UUID.
ResolveSubnetViaV3List() {
    local v3Ep="${BASE_URL}/api/nutanix/v3/subnets/list"
    local off=0
    local lim="${SUBNET_LIST_PAGE_LIMIT}"
    local v3Resp v3Code v3Body tot got matched
    stage "Resolve subnet by name via v3 POST /subnets/list (networking v4.2 list unavailable)"
    verbose_warning "GET /api/networking/v4.2/config/subnets returned HTTP 404 — using v3 subnets/list for name → uuid and subnet header fields."
    matched=""
    while true; do
        local reqJson
        reqJson=$(jq -nc --argjson o "$off" --argjson l "$lim" '{kind:"subnet",offset:$o,length:$l}')
        v3Resp=$(make_api_request "POST" "$v3Ep" "$reqJson")
        v3Code=$(printf '%s\n' "$v3Resp" | tail -n1)
        v3Body=$(printf '%s\n' "$v3Resp" | sed '$d')
        if [ "$v3Code" != "200" ]; then
            error "v3 subnets/list failed HTTP ${v3Code} (POST ${v3Ep})"
            printf '%s\n' "$v3Body" >&2
            return 1
        fi
        if [ "$VERBOSE" = true ]; then
            echo "========== v3 subnets/list parse (offset=${off}, length=${lim}) ==========" >&2
            printf '%s\n' "$v3Body" | jq -c '
                {
                  api_version,
                  metadata: .metadata,
                  entityCount: ((.entities // []) | length),
                  names: [ (.entities // [])[] | (.spec.name // .status.name // empty) ] | map(select(. != ""))
                }
            ' >&2 2>/dev/null || printf '%s\n' "$v3Body" >&2
            echo "========== end v3 parse summary ==========" >&2
        fi
        matched=$(printf '%s\n' "$v3Body" | jq -c --arg n "$FILTER_SUBNET_NAME" '
            (.entities // [])[] | select((.spec.name // .status.name // "") == $n)' 2>/dev/null | head -n1)
        if [ -n "$matched" ]; then
            printf '%s\n' "$matched" > "$SUBNET_V3_ENTITY_FILE"
            FILTER_SUBNET_UUID=$(jq -r '.metadata.uuid // empty' "$SUBNET_V3_ENTITY_FILE")
            if [ -z "$FILTER_SUBNET_UUID" ] || [ "$FILTER_SUBNET_UUID" = "null" ]; then
                error "v3 entity matched name \"${FILTER_SUBNET_NAME}\" but metadata.uuid was empty."
                if [ "$VERBOSE" = true ]; then
                    echo "========== v3 matched entity (raw) ==========" >&2
                    printf '%s\n' "$matched" >&2
                    echo "========== end ==========" >&2
                fi
                return 1
            fi
            if [ "$VERBOSE" = true ]; then
                echo "========== v3 matched entity for \"${FILTER_SUBNET_NAME}\" (full JSON for field mapping) ==========" >&2
                jq . "$SUBNET_V3_ENTITY_FILE" >&2
                echo "========== end v3 matched entity ==========" >&2
            fi
            return 0
        fi
        got=$(printf '%s\n' "$v3Body" | jq '(.entities // []) | length' 2>/dev/null || echo "0")
        tot=$(printf '%s\n' "$v3Body" | jq -r '.metadata.total_matches // empty' 2>/dev/null || true)
        if [ -z "$tot" ] || ! [ "$tot" -eq "$tot" ] 2>/dev/null; then
            [ "$got" -eq 0 ] && break
            [ "$got" -lt "$lim" ] && break
        else
            off=$((off + got))
            [ "$off" -ge "$tot" ] && break
            [ "$got" -eq 0 ] && break
        fi
    done
    error "Subnet not found via v3 list: \"${FILTER_SUBNET_NAME}\""
    return 1
}

# Resolve FILTER_SUBNET_NAME → FILTER_SUBNET_UUID and SUBNET_SOURCE (v4.2 list or v3 list on 404).
ResolveSubnetIdentityFromName() {
    stage "Resolve subnet id by name (v4.2 GET /config/subnets, paginated)"
    SUBNET_SOURCE="v42"
    FILTER_SUBNET_UUID=""
    SUBNET_LIST_PAGE=0
    while true; do
        EP="${BASE_URL}/api/networking/v4.2/config/subnets?\$page=${SUBNET_LIST_PAGE}&\$limit=${SUBNET_LIST_PAGE_LIMIT}"
        RESP=$(make_api_request "GET" "$EP")
        CODE=$(printf '%s\n' "$RESP" | tail -n1)
        BODY=$(printf '%s\n' "$RESP" | sed '$d')
        if [ "$CODE" != "200" ]; then
            if [ "$SUBNET_LIST_PAGE" -eq 0 ] && [ "$CODE" = "404" ]; then
                SUBNET_SOURCE="v3"
                ResolveSubnetViaV3List || exit 1
                break
            fi
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

    if [ "$SUBNET_SOURCE" = "v42" ]; then
        if [ -z "$FILTER_SUBNET_UUID" ] || [ "$FILTER_SUBNET_UUID" = "null" ]; then
            error "Subnet not found: \"${FILTER_SUBNET_NAME}\""
            exit 1
        fi
    fi
    stage "Subnet found (${SUBNET_SOURCE}): id=${FILTER_SUBNET_UUID}"
}

if [ -n "$CHECK_IP" ]; then
    if [ -n "$FILTER_SUBNET_NAME" ]; then
        ResolveSubnetIdentityFromName
    else
        FILTER_SUBNET_UUID=""
    fi
    RunCheckIpAcrossVms
    success "Check complete"
    exit 0
fi

ResolveSubnetIdentityFromName

# --- Subnet config for report header (v4.2 GET or v3 entity fields) ---
if [ "$SUBNET_SOURCE" = "v42" ]; then
    stage "GET subnet config (CIDR, DHCP pool) for report header (v4.2)"
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
else
    stage "Subnet header from v3 entity (skipping v4.2 subnet GET)"
    SUBNET_CIDR=$(jq -r '
      ( .status.resources.ip_config // .spec.resources.ip_config )
      | if . == null then empty else "\(.subnet_ip)/\(.prefix_length)" end
    ' "$SUBNET_V3_ENTITY_FILE" 2>/dev/null)
    [ -z "$SUBNET_CIDR" ] || [ "$SUBNET_CIDR" = "null" ] && SUBNET_CIDR="(unknown)"

    DHCP_POOL_TXT=$(jq -r '
      [ ( .status.resources.ip_config.pool_list // .spec.resources.ip_config.pool_list // [] )[]
        | .range // empty
        | gsub(" "; "-")
      ]
      | if length > 0 then join(", ") else empty end
    ' "$SUBNET_V3_ENTITY_FILE" 2>/dev/null)
    [ -z "$DHCP_POOL_TXT" ] && DHCP_POOL_TXT="(no pool in v3 entity)"

    # First pool "start end" for static-range math (same role as v4.2 poolList[0])
    firstRange=$(jq -r '
      ( .status.resources.ip_config.pool_list // .spec.resources.ip_config.pool_list // [] )[0].range // empty
    ' "$SUBNET_V3_ENTITY_FILE" 2>/dev/null)
    DHCP_START=""
    DHCP_END=""
    if [ -n "$firstRange" ]; then
        read -r DHCP_START DHCP_END <<< "$(echo "$firstRange" | awk '{print $1,$2}')"
    fi
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

# v3 subnet mode: when networking v4.2 /vnics is missing, discover VM uuids via v3 /vms/list (FIQL or full scan + NIC filter).
PopulateVmIdsViaV3Subnet() {
    local subnetUuid="${1:?}"
    local ep="${BASE_URL}/api/nutanix/v3/vms/list"
    local lim=500
    local off resp code body uuids

    UuidsFromV3VmListJson() {
        printf '%s\n' "$1" | jq -r --arg su "$subnetUuid" '
            def subId(n):
                (n.subnet_reference
                 | if . == null then ""
                   elif type == "object" then (.uuid // "")
                   else (. | tostring) end);
            (.entities // [])[]
            | select(
                [ (.status.resources.nic_list // [])[], (.spec.resources.nic_list // [])[] ]
                | map(subId(.))
                | any(. == $su)
              )
            | .metadata.uuid // empty
        ' 2>/dev/null | awk 'NF'
    }

    stage "v3 VMs list: try FIQL nic_list/subnet_reference==${subnetUuid}"
    body=$(jq -nc --arg su "$subnetUuid" '{kind:"vm",filter:("nic_list/subnet_reference=="+$su),length:500,offset:0}')
    resp=$(make_api_request "POST" "$ep" "$body")
    code=$(printf '%s\n' "$resp" | tail -n1)
    body=$(printf '%s\n' "$resp" | sed '$d')
    if [ "$code" = "200" ]; then
        uuids=$(UuidsFromV3VmListJson "$body")
        if [ -n "$uuids" ]; then
            printf '%s\n' "$uuids"
            return 0
        fi
        if [ "$VERBOSE" = true ]; then
            info "v3 vms/list FIQL returned no matching VMs (or empty entities); falling back to paginated list + client NIC filter."
        fi
    elif [ "$VERBOSE" = true ]; then
        info "v3 vms/list FIQL returned HTTP ${code}; falling back to paginated list + client NIC filter."
    fi

    stage "v3 VMs list: paginate without filter (max ${lim} per page), filter NICs to subnet ${subnetUuid}"
    off=0
    while true; do
        body=$(jq -nc --argjson o "$off" --argjson l "$lim" '{kind:"vm",length:$l,offset:$o}')
        resp=$(make_api_request "POST" "$ep" "$body")
        code=$(printf '%s\n' "$resp" | tail -n1)
        body=$(printf '%s\n' "$resp" | sed '$d')
        if [ "$code" != "200" ]; then
            warning "v3 vms/list failed HTTP ${code} at offset=${off}"
            return 1
        fi
        uuids=$(UuidsFromV3VmListJson "$body")
        [ -n "$uuids" ] && printf '%s\n' "$uuids"
        got=$(printf '%s\n' "$body" | jq '(.entities // []) | length' 2>/dev/null || echo "0")
        tot=$(printf '%s\n' "$body" | jq -r '.metadata.total_matches // empty' 2>/dev/null || true)
        [ "$got" -eq 0 ] && break
        if [ -n "$tot" ] && [ "$tot" -gt 0 ] 2>/dev/null; then
            off=$((off + got))
            [ "$off" -ge "$tot" ] && break
        elif [ "$got" -lt "$lim" ]; then
            break
        else
            off=$((off + got))
        fi
    done
    return 0
}

# IPs on NICs attached to subnet $2 from a v3 VM GET (or list) JSON body at $1 (root entity, not .data).
# Only ip_endpoint_list entries with type LEARNED (guest-reported), matching v4.2 learnedIpAddresses — not ASSIGNED.
IpsFromV3VmEntityForSubnet() {
    local entityJson="${1:?}"
    local subnetUuid="${2:?}"
    printf '%s\n' "$entityJson" | jq -r --arg su "$subnetUuid" '
        def subId(n):
            (n.subnet_reference
             | if . == null then ""
               elif type == "object" then (.uuid // "")
               else (. | tostring) end);
        [
          (.status.resources.nic_list // [])[],
          (.spec.resources.nic_list // [])[]
          | select(subId(.) == $su)
          | (.ip_endpoint_list // [])[]
          | select(((.type // "") | ascii_upcase) == "LEARNED")
          | (.ip // empty) | strings
        ]
        | map(select(. != ""))
        | unique
        | join(",")
    ' 2>/dev/null
}

# --- VM UUIDs: v4.2 /vnics only (paginated) ---
stage "List vNICs on subnet → collect unique VM extIds (paginated)"
vpage=0
while true; do
    VEP="${BASE_URL}/api/networking/v4.2/config/subnets/${FILTER_SUBNET_UUID}/vnics?\$page=${vpage}&\$limit=${VNICS_PAGE_LIMIT}"
    VR=$(make_api_request "GET" "$VEP")
    vc=$(printf '%s\n' "$VR" | tail -n1)
    vb=$(printf '%s\n' "$VR" | sed '$d')
    if [ "$vc" != "200" ]; then
        if [ "$SUBNET_SOURCE" = "v3" ]; then
            verbose_warning "vNICs GET failed HTTP ${vc}"
            verbose_warning "Subnet was resolved via v3; will try v3 POST /vms/list to find VMs on this subnet (v4.2 /vnics unavailable)."
        else
            warning "vNICs GET failed HTTP ${vc}"
        fi
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

if [ "$SUBNET_SOURCE" = "v3" ] && [ ! -s "$VM_IDS_FILE" ]; then
    stage "Collect VM UUIDs via v3 POST /vms/list (v4.2 subnet/vnics unavailable or empty)"
    PopulateVmIdsViaV3Subnet "$FILTER_SUBNET_UUID" >> "$VM_IDS_FILE" || true
fi

awk 'NF' "$VM_IDS_FILE" | sort -u > "${TMP_DIR}/vm_ids.u" && mv "${TMP_DIR}/vm_ids.u" "$VM_IDS_FILE"

VM_COUNT=$(wc -l < "$VM_IDS_FILE" | tr -d '[:space:]')
[ -z "$VM_COUNT" ] && VM_COUNT=0
stage "Unique VMs attached to subnet: ${VM_COUNT}"

if [ "$VM_COUNT" -gt 0 ]; then
    stage "Per-VM: IPs on NICs for this subnet (v4.2 AHV VM GET, or v3 VM GET when v4.2 unavailable)"
    # --- Per VM: v4.2 learnedIpAddresses, or v3 ip_endpoint_list on NICs for this subnet uuid ---
    while IFS= read -r VM_UUID; do
        [ -z "$VM_UUID" ] && continue
        VM_EP="${BASE_URL}/api/vmm/v4.2/ahv/config/vms/${VM_UUID}"
        VR=$(make_api_request "GET" "$VM_EP")
        VC=$(printf '%s\n' "$VR" | tail -n1)
        VB=$(printf '%s\n' "$VR" | sed '$d')
        VM_NAME=""
        IPS=""
        if [ "$VC" = "200" ]; then
            VM_NAME=$(printf '%s\n' "$VB" | jq -r '.data.name // "Unknown"' 2>/dev/null)
            IPS=$(printf '%s\n' "$VB" | jq -r --arg su "$FILTER_SUBNET_UUID" '
                [
                  .data.nics[]?
                  | select(
                      ((.nicNetworkInfo.subnet.extId // "") == $su)
                      or ((.networkInfo.subnet.extId // "") == $su)
                      or ((.nicNetworkInfo.subnet.uuid // "") == $su)
                      or ((.networkInfo.subnet.uuid // "") == $su)
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
        fi
        if [ -z "$IPS" ] || [ "$IPS" = "null" ]; then
            VM_EP3="${BASE_URL}/api/nutanix/v3/vms/${VM_UUID}"
            VR3=$(make_api_request "GET" "$VM_EP3")
            VC3=$(printf '%s\n' "$VR3" | tail -n1)
            VB3=$(printf '%s\n' "$VR3" | sed '$d')
            if [ "$VC3" = "200" ]; then
                [ -z "$VM_NAME" ] || [ "$VM_NAME" = "Unknown" ] && VM_NAME=$(printf '%s\n' "$VB3" | jq -r '.status.name // .spec.name // .metadata.uuid // "Unknown"' 2>/dev/null)
                IPS=$(IpsFromV3VmEntityForSubnet "$VB3" "$FILTER_SUBNET_UUID")
            elif [ "$VC" != "200" ]; then
                warning "VM GET failed for ${VM_UUID} (v4.2 HTTP ${VC}, v3 HTTP ${VC3}), skipping."
                continue
            fi
        fi

        if [ -n "$IPS" ] && [ "$IPS" != "null" ]; then
            echo "${VM_NAME}|${IPS}" >> "$STATIC_ROWS_FILE"
        fi
    done < "$VM_IDS_FILE"
fi

# --- Report (stdout) ---
stage "Write report to stdout"
echo "subnet: ${FILTER_SUBNET_NAME}"
echo "subnet range: ${SUBNET_CIDR}"
echo "DHCP pool: ${DHCP_POOL_TXT}"
echo "static range: ${STATIC_RANGE_TXT}"
echo "Used Static IPs:"
if [ "$VM_COUNT" -eq 0 ]; then
    echo "  (no VMs returned for this subnet)"
elif [ ! -s "$STATIC_ROWS_FILE" ]; then
    echo "  (no static IPs discovered on this subnet)"
else
    sort -t'|' -k1,1 "$STATIC_ROWS_FILE" | while IFS='|' read -r rname rips; do
        echo "  |_${rname}: ${rips}"
    done
fi

EmitK8sClustersOnSubnet "$FILTER_SUBNET_NAME"

echo ""
success "Report complete"
