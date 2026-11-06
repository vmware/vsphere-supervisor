#!/bin/bash
#
# Run from a workstation that has ssh(1) and sshpass(1). The script SSHs to the
# vCenter appliance as root (password via sshpass), then on vCenter:
#
# add:
#   - Resolves cluster via GET .../supervisors/<id>/topology (zone cluster list) and
#     /usr/lib/vmware-wcp/decryptK8Pwd.py: first cluster id from decrypt output that appears
#     in topology is used for GET .../clusters/<id> api_servers and Control Plane VM IP filtering.
#   - Generates a local CA and server cert for depot-image-proxy.kube-system.svc.cluster.local.
#   - On each Control Plane: TLS, nginx conf.d (listen 5005): map+realm rewrite for Bearer www-authenticate, Artifactory token auth location,
#     vcf-depot CA, LoadBalancer Service (port 443 -> target 5005), then
#     waits for LB ingress IP and appends depot FQDN -> IP to /etc/vmware/wcp/coredns/hosts (script markers), chmod 644 hosts,
#     rollout restart kube-system/coredns, static pod bounce.
#   - Safe to re-run over an earlier install: conf.d, TLS, Service and CoreDNS entries are overwritten on every
#     Control Plane, and an existing depot-registry is deleted and re-created with the regenerated CA.
#   - POSTs depot-registry (image_registry.port 443) to .../supervisors/<SUPERVISOR_ID>/container-image-registries
#     using CreateSpec: name, default_registry, image_registry { hostname, port, certificate_chain, ... }.
#
# remove:
#   - Same cluster / Control Plane VM discovery as add, then if depot-registry exists on the supervisor, DELETE it via vCenter API.
#   - On each Control Plane: remove 30-depot-images.conf, depot TLS files, script-managed CoreDNS hosts block (chmod 644 if present), rollout
#     restart kube-system/coredns, Service, bounce static pod.
#
# Usage:
#   ./manage-depot-image-proxy.sh add    VC_HOST VC_ROOT_SSH_PASSWORD VC_ADMIN_USER VC_ADMIN_PASSWORD SUPERVISOR_ID
#   ./manage-depot-image-proxy.sh remove VC_HOST VC_ROOT_SSH_PASSWORD VC_ADMIN_USER VC_ADMIN_PASSWORD SUPERVISOR_ID
#
# VC_HOST is used for SSH (root) and for https://VC_HOST/api/... REST calls from vCenter.
#
# Control Plane VM SSH (vCenter -> each Supervisor Control Plane VM): root password is the PWD: value from the same
# decryptK8Pwd.py output as the matched cluster (after Cluster: and IP:). sshpass must be
# installed on vCenter for these hops.

set -euo pipefail

SCRIPT_NAME="${0##*/}"

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} add    VC_HOST VC_ROOT_SSH_PASSWORD VC_ADMIN_USER VC_ADMIN_PASSWORD SUPERVISOR_ID
  ${SCRIPT_NAME} remove VC_HOST VC_ROOT_SSH_PASSWORD VC_ADMIN_USER VC_ADMIN_PASSWORD SUPERVISOR_ID

  VC_HOST                 vCenter host domain (must match server cert; SSH as root; also REST https host)
  VC_ROOT_SSH_PASSWORD    root password for sshpass to vCenter
  VC_ADMIN_USER           vCenter API user (e.g. administrator@vsphere.local)
  VC_ADMIN_PASSWORD       vCenter API password
  SUPERVISOR_ID           Supervisor ID for container-image-registries

Requires: ssh, sshpass on your workstation (vCenter hop). On vCenter: sshpass must also be
installed for Control Plane VM hops (password from decryptK8Pwd.py PWD: line). Passwords may be visible
in process listings; quote arguments that contain shell metacharacters.

VC_ROOT_SSH_PASSWORD is only for workstation -> vCenter (root). Supervisor Control Plane VM root SSH from
vCenter uses the PWD value from /usr/lib/vmware-wcp/decryptK8Pwd.py for the matched cluster.

Options:
  -h, --help    Show this message
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

[[ $# -eq 6 ]] || die "Expected 6 arguments: add|remove and five credentials (use --help)"

OPERATION="$1"
case "${OPERATION}" in
    add | remove) ;;
    *) die "First argument must be 'add' or 'remove'" ;;
esac
shift

VC_HOST="$1"
VC_SSH_PASSWORD="$2"
VC_ADMIN_USER="$3"
VC_ADMIN_PASSWORD="$4"
SUPERVISOR_ID="$5"

command -v sshpass >/dev/null 2>&1 || die "sshpass is required (e.g. install sshpass)"
command -v ssh >/dev/null 2>&1 || die "ssh is required"

# shellcheck disable=SC2029
# Do not use BatchMode=yes here: it disables password and keyboard-interactive auth, so sshpass cannot sign in.
exec sshpass -p "${VC_SSH_PASSWORD}" ssh \
    -o BatchMode=no \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "root@${VC_HOST}" \
    bash -s -- "${VC_HOST}" "${VC_ADMIN_USER}" "${VC_ADMIN_PASSWORD}" "${SUPERVISOR_ID}" "${OPERATION}" <<'REMOTE'
set -euo pipefail

VC_API_HOST="$1"
VC_ADMIN_USER="$2"
VC_ADMIN_PASSWORD="$3"
SUPERVISOR_ID="$4"
OPERATION="$5"

readonly DEPOT_REGISTRY_NAME="depot-registry"
readonly K8S_DECRYPT_CMD="/usr/lib/vmware-wcp/decryptK8Pwd.py"
readonly SERVER_SAN_DNS="depot-image-proxy.kube-system.svc.cluster.local"
readonly DEPOT_PROXY_LISTEN_PORT=5005
readonly DEPOT_PROXY_SVC_PORT=443
readonly NGINX_DEPOT_PROXY_CONF="/etc/vmware/wcp/nginx/conf.d/30-depot-images.conf"
readonly MANIFEST="/etc/kubernetes/manifests/kubectl-plugin-vsphere.yaml"
readonly COREDNS_HOSTS="/etc/vmware/wcp/coredns/hosts"

CP_ROOT_PASSWORD=""

declare -A TOPOLOGY_CLUSTER_SET=()

WORKDIR=""
VC_CACERT=""

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/depot-image-proxy.XXXXXX")"

fetch_vc_ca() {
    local zipf certdir pemf
    zipf="${WORKDIR}/vc-certs.zip"
    certdir="${WORKDIR}/vc-certs"
    pemf="${certdir}/certs/lin/ca-certs.pem"

    # Bootstrap fetch: -k is unavoidable here since we don't yet have the CA cert.
    curl -ksSf "https://${VC_API_HOST}/certs/download.zip" -o "${zipf}" \
        || die "Failed to download vCenter certs zip"
    mkdir -p "${certdir}"
    bsdtar -xf "${zipf}" -C "${certdir}" \
        || die "Failed to bsdtar vCenter certs"
    # Concatenate all trusted root PEMs (*.0 files) into a single bundle.
    : > "${pemf}"
    local f
    for f in "${certdir}/certs/lin/"*.0; do
        [[ -f "${f}" ]] || continue
        cat "${f}" >> "${pemf}"
    done
    [[ -s "${pemf}" ]] || die "No *.0 cert files found in certs/lin/ from vCenter certs zip"
    VC_CACERT="--cacert ${pemf}"
    log "Fetched vCenter CA cert bundle (${pemf})"
}

vc_session() {
    local out
    # shellcheck disable=SC2086
    out="$(curl -sS ${VC_CACERT} -u "${VC_ADMIN_USER}:${VC_ADMIN_PASSWORD}" \
        -X POST "https://${VC_API_HOST}/api/session")" || die "vCenter session POST failed"
    SESSION_TOKEN="$(printf '%s' "${out}" | tr -d '"\r\n')"
    [[ -n "${SESSION_TOKEN}" ]] || die "Empty session token from vCenter"
}

uri_path_escape() {
    printf '%s' "$1" | jq -sRr @uri
}

# sshpass + password auth to each Control Plane VM (BatchMode=no so password auth is allowed).
setup_cp_ssh() {
    command -v sshpass >/dev/null 2>&1 || die "sshpass is required on vCenter for CP SSH (install sshpass on the appliance)"
    [[ -n "${CP_ROOT_PASSWORD}" ]] || die "Control Plane VM root password empty (missing PWD: line after IP for matched cluster in ${K8S_DECRYPT_CMD} output)"
    SSH_CP=(
        sshpass -p "${CP_ROOT_PASSWORD}"
        ssh
        -o BatchMode=no
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password,keyboard-interactive
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
    )
    SCP_CP=(
        sshpass -p "${CP_ROOT_PASSWORD}"
        scp
        -o BatchMode=no
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password,keyboard-interactive
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
    )
}

fetch_supervisor_topology_clusters() {
    local enc url resp
    enc="$(uri_path_escape "${SUPERVISOR_ID}")"
    url="https://${VC_API_HOST}/api/vcenter/namespace-management/supervisors/${enc}/topology"
    # shellcheck disable=SC2086
    resp="$(curl -sS ${VC_CACERT} -H "vmware-api-session-id: ${SESSION_TOKEN}" "${url}")" \
        || die "GET supervisor topology failed"
    local -a ids
    mapfile -t ids < <(printf '%s' "${resp}" | jq -r '.[]?.clusters[]? | select(type=="string")') \
        || die "jq failed parsing supervisor topology"
    ((${#ids[@]} > 0)) || die "Supervisor topology returned no cluster IDs"
    TOPOLOGY_CLUSTER_SET=()
    for c in "${ids[@]}"; do
        c="$(printf '%s' "${c}" | tr -d '\r\n')"
        [[ -n "${c}" ]] || continue
        TOPOLOGY_CLUSTER_SET["${c}"]=1
    done
    log "Supervisor topology clusters: ${ids[*]}"
}

# Parses decryptK8Pwd.py stdout: Cluster: <id>:..., then IP: <addr>, then PWD: <password>
# for that block. Emits "cluster_id<TAB>ip<TAB>password" per block; first line whose
# cluster_id is in supervisor topology wins.
discover_cluster_id_and_float_from_topology() {
    fetch_supervisor_topology_clusters

    [[ -x "${K8S_DECRYPT_CMD}" ]] || die "Missing or not executable: ${K8S_DECRYPT_CMD}"
    local raw pairs
    raw="$("${K8S_DECRYPT_CMD}" 2>&1)" || die "${K8S_DECRYPT_CMD} failed (stderr mixed in output)"

    pairs="$(printf '%s\n' "${raw}" | awk '
        function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
        }
        {
            gsub(/\r/, "")
        }
        /^[[:space:]]*Cluster:/ {
            pending_ip = ""
            s = $0
            sub(/^[[:space:]]*Cluster:[[:space:]]*/, "", s)
            colon = index(s, ":")
            if (colon > 0) {
                pending = trim(substr(s, 1, colon - 1))
            } else {
                pending = trim(s)
            }
            next
        }
        /^[[:space:]]*IP:/ && pending != "" {
            pending_ip = $2
            next
        }
        /^[[:space:]]*PWD:/ && pending != "" && pending_ip != "" {
            pwdline = $0
            sub(/^[[:space:]]*PWD:[[:space:]]*/, "", pwdline)
            print pending "\t" pending_ip "\t" pwdline
            pending = ""
            pending_ip = ""
            next
        }
    ')"

    CLUSTER_ID=""
    FLOAT_IP=""
    CP_ROOT_PASSWORD=""
    if [[ -z "${pairs// }" ]]; then
        die "Could not parse any Cluster:/IP:/PWD: triples from ${K8S_DECRYPT_CMD} output"
    fi
    while IFS=$'\t' read -r cid ip rootpw || [[ -n "${cid}" ]]; do
        cid="$(printf '%s' "${cid}" | tr -d '\r\n')"
        ip="$(printf '%s' "${ip}" | tr -d '\r\n')"
        rootpw="$(printf '%s' "${rootpw}" | tr -d '\r\n')"
        [[ -n "${cid}" && -n "${ip}" && -n "${rootpw}" ]] || continue
        if [[ -n "${TOPOLOGY_CLUSTER_SET[$cid]:-}" ]]; then
            CLUSTER_ID="${cid}"
            FLOAT_IP="${ip}"
            CP_ROOT_PASSWORD="${rootpw}"
            break
        fi
    done <<< "${pairs}"

    [[ -n "${CLUSTER_ID}" ]] || die "No cluster from ${K8S_DECRYPT_CMD} matches supervisor topology (supervisor ${SUPERVISOR_ID}). Topology: ${!TOPOLOGY_CLUSTER_SET[*]}; check decrypt Cluster lines vs topology clusters."
    [[ -n "${FLOAT_IP}" ]] || die "No floating IP paired with matched cluster in decrypt output"
    [[ -n "${CP_ROOT_PASSWORD}" ]] || die "No PWD for matched cluster in ${K8S_DECRYPT_CMD} output (expected PWD: after IP: for that cluster)"
    setup_cp_ssh
    log "Matched cluster_id=${CLUSTER_ID} floating_ip=${FLOAT_IP}"
}

discover_cp_ips() {
    local resp prefix enc_cluster
    prefix="$(printf '%s' "${FLOAT_IP}" | cut -d. -f1-2)."
    [[ "${prefix}" != "." ]] || die "Invalid floating IP for prefix: ${FLOAT_IP}"
    enc_cluster="$(uri_path_escape "${CLUSTER_ID}")"
    # shellcheck disable=SC2086
    resp="$(curl -sS ${VC_CACERT} -H "vmware-api-session-id: ${SESSION_TOKEN}" \
        "https://${VC_API_HOST}/api/vcenter/namespace-management/clusters/${enc_cluster}")" \
        || die "GET namespace-management/clusters/${CLUSTER_ID} failed"
    mapfile -t CP_IPS < <(printf '%s' "${resp}" | jq -r --arg fp "${FLOAT_IP}" --arg p "${prefix}" \
        '.api_servers[]? | select(type=="string") | select(startswith($p) and . != $fp)') \
        || die "jq failed parsing api_servers"
    ((${#CP_IPS[@]} > 0)) || die "No control plane VM IPs after filtering (prefix ${prefix}, exclude ${FLOAT_IP})"
    log "Control Plane VM management IPs (${#CP_IPS[@]}): ${CP_IPS[*]}"
}

registry_list_url() {
    local enc
    enc="$(uri_path_escape "${SUPERVISOR_ID}")"
    printf 'https://%s/api/vcenter/namespace-management/supervisors/%s/container-image-registries' \
        "${VC_API_HOST}" "${enc}"
}

# Resolves registry id for DELETE (path segment); empty if not present.
depot_registry_id_from_list() {
    local list_json
    # shellcheck disable=SC2086
    list_json="$(curl -sS ${VC_CACERT} -H "vmware-api-session-id: ${SESSION_TOKEN}" "$(registry_list_url)")" \
        || die "GET container-image-registries list failed"
    printf '%s' "${list_json}" | jq -r --arg n "${DEPOT_REGISTRY_NAME}" '
        ([.[]? | select(.name == $n)] | first) as $r
        | if $r == null then empty
          elif ($r.id | type) == "string" then $r.id
          elif ($r.id | type) == "object" and ($r.id | has("id")) then $r.id.id
          else ($r.id | tostring)
          end
    ' | head -1
}

unregister_depot_registry() {
    local reg_id enc_id url status outf
    outf="$(mktemp)"
    reg_id="$(depot_registry_id_from_list | tr -d '\r\n')"
    if [[ -z "${reg_id}" ]]; then
        log "No ${DEPOT_REGISTRY_NAME} registry on supervisor; skipping vCenter DELETE"
        rm -f "${outf}"
        return 0
    fi
    enc_id="$(printf '%s' "${reg_id}" | jq -sRr @uri)"
    url="$(registry_list_url)/${enc_id}"
    # shellcheck disable=SC2086
    status="$(curl -sS ${VC_CACERT} -o "${outf}" -w '%{http_code}' \
        -X DELETE \
        -H "vmware-api-session-id: ${SESSION_TOKEN}" \
        "${url}")" || die "curl DELETE container-image-registry failed"

    if [[ "${status}" == "204" || "${status}" == "404" ]]; then
        log "Removed ${DEPOT_REGISTRY_NAME} from supervisor (HTTP ${status})"
        rm -f "${outf}"
        return 0
    fi
    log "vCenter DELETE response HTTP ${status}:"
    cat "${outf}" >&2 || true
    rm -f "${outf}"
    die "Unexpected HTTP status removing container image registry"
}

write_nginx_template() {
    local tpl="${WORKDIR}/depot-nginx.tpl"
    cat >"${tpl}" <<'TPL'
map $upstream_http_www_authenticate $depot_www_authenticate {
    default "";
    '~(?<pre>.*)realm="[^"]+"(?<post>.*)' '${pre}realm="__DEPOT_REALM_BASE__"${post}';
}

server {
    listen __DEPOT_LISTEN_PORT__ ssl;
    server_name depot-image-proxy.kube-system.svc.cluster.local;

    ssl_certificate     /etc/vmware/wcp/tls/depot-image-proxy.crt;
    ssl_certificate_key /etc/vmware/wcp/tls/depot-image-proxy.key;
    include /etc/vmware/wcp/nginx/tls.conf;

    location __AUTH_LOCATION__ {
        resolver 127.0.0.53;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_cache off;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 8;
        proxy_ssl_trusted_certificate /etc/vmware/wcp/tls/depot-image-registry-trusted.crt;
        proxy_http_version 1.1;

        set $depot_registry_host __DEPOT_HOST__;
        proxy_ssl_name $depot_registry_host;
        proxy_ssl_server_name on;
        proxy_set_header Host $depot_registry_host;

        set $depot_registry_upstream __DEPOT_UPSTREAM__;
        proxy_pass $depot_registry_upstream;
    }

    location /v2 {
        resolver 127.0.0.53;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_cache off;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 8;
        proxy_ssl_trusted_certificate /etc/vmware/wcp/tls/depot-image-registry-trusted.crt;
        proxy_http_version 1.1;

        set $depot_registry_host __DEPOT_HOST__;
        proxy_ssl_name $depot_registry_host;
        proxy_ssl_server_name on;
        proxy_set_header Host $depot_registry_host;

        set $depot_registry_upstream __DEPOT_UPSTREAM__;
        proxy_pass $depot_registry_upstream;

        proxy_hide_header www-authenticate;
        add_header www-authenticate $depot_www_authenticate always;

        if ($request_method !~ ^(GET|HEAD)$) {
            return 403;
        }
    }
}
TPL
}

gen_depot_tls() {
    local cakey cacrt srvkey csr srvcrt ext
    cakey="${WORKDIR}/depot-image-proxy-ca.key"
    cacrt="${WORKDIR}/depot-image-proxy-ca.crt"
    srvkey="${WORKDIR}/depot-image-proxy.key"
    csr="${WORKDIR}/depot-image-proxy.csr"
    srvcrt="${WORKDIR}/depot-image-proxy.crt"
    ext="${WORKDIR}/depot-image-proxy.ext"

    openssl genrsa -out "${cakey}" 4096 >/dev/null 2>&1
    openssl req -x509 -new -nodes -key "${cakey}" -sha256 -days 3650 -out "${cacrt}" \
        -subj "/CN=depot-image-proxy-ca/O=WCP/OU=Supervisor" >/dev/null 2>&1

    openssl genrsa -out "${srvkey}" 2048 >/dev/null 2>&1
    openssl req -new -key "${srvkey}" -out "${csr}" \
        -subj "/CN=${SERVER_SAN_DNS}" >/dev/null 2>&1

    cat >"${ext}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${SERVER_SAN_DNS}
EOF

    openssl x509 -req -in "${csr}" -CA "${cacrt}" -CAkey "${cakey}" -CAcreateserial \
        -out "${srvcrt}" -days 825 -sha256 -extfile "${ext}" >/dev/null 2>&1

    chmod go-rwx "${cakey}" "${srvkey}"
    write_nginx_template
    log "Generated CA and server cert in ${WORKDIR}"
}

scp_tls_and_tpl() {
    local cp="$1"
    "${SCP_CP[@]}" \
        "${WORKDIR}/depot-image-proxy.crt" \
        "${WORKDIR}/depot-image-proxy.key" \
        "${WORKDIR}/depot-image-proxy-ca.crt" \
        "${WORKDIR}/depot-nginx.tpl" \
        "root@${cp}:/tmp/" || die "scp to ${cp} failed"
}

remote_install_on_cp() {
    local cp="$1"
    "${SSH_CP[@]}" "root@${cp}" bash -s \
        "${NGINX_DEPOT_PROXY_CONF}" \
        "${MANIFEST}" \
        "${COREDNS_HOSTS}" \
        "${SERVER_SAN_DNS}" \
        "${DEPOT_PROXY_LISTEN_PORT}" \
        <<'EOS'
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NGINX_DEPOT_PROXY_CONF="$1"
MANIFEST="$2"
COREDNS_HOSTS="$3"
DEPOT_FQDN="$4"
DEPOT_LISTEN_PORT="$5"
SCRIPT_HOSTS_MARK="# MANUALLY UPDATED BY SCRIPT"

remove_depot_coredns_manual_block() {
    local f="$1" fqdn="$2"
    [[ -f "$f" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    awk -v fqdn="$fqdn" '
        function t(s) { gsub(/\r/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        t($0) == "# MANUALLY UPDATED BY SCRIPT" {
            first = $0
            if (getline second <= 0) { print first; next }
            if (index(second, fqdn) > 0) {
                if (getline third <= 0) { print first; print second; next }
                if (t(third) == "# MANUALLY UPDATED BY SCRIPT") { next }
                print first; print second; print third; next
            }
            print first; print second; next
        }
        { print }
    ' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

wait_depot_lb_ip() {
    local ip hn n
    for ((n = 1; n <= 90; n++)); do
        ip="$(kubectl get svc depot-image-proxy -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | tr -d '\r\n')"
        if [[ -n "${ip}" ]]; then
            printf '%s' "${ip}"
            return 0
        fi
        hn="$(kubectl get svc depot-image-proxy -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null | tr -d '\r\n')"
        if [[ -n "${hn}" ]]; then
            ip="$(getent ahosts "${hn}" 2>/dev/null | awk '/STREAM/ { print $1; exit }')"
            if [[ -n "${ip}" ]]; then
                printf '%s' "${ip}"
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

kubectl get managementservices vcf-depot >/dev/null 2>&1 || { echo "vcf-depot ManagementService missing" >&2; exit 1; }

RAW_ADDR="$(kubectl get managementservices vcf-depot -o jsonpath='{.spec.managementAddresses[0]}')"
[[ -n "${RAW_ADDR// }" ]] || { echo "empty managementAddresses[0]" >&2; exit 1; }

case "${RAW_ADDR}" in
    http://*|https://*) DEPOT_UPSTREAM="${RAW_ADDR}" ;;
    *) DEPOT_UPSTREAM="https://${RAW_ADDR}" ;;
esac
DEPOT_HOST="${DEPOT_UPSTREAM#https://}"
DEPOT_HOST="${DEPOT_HOST#http://}"
DEPOT_HOST="${DEPOT_HOST%%/*}"

# Path on depot-image-proxy for OAuth/token traffic (realm + dedicated location; separate from /v2 so POSTs skip the GET|HEAD if).
readonly AUTH_LOCATION_PATH="/artifactory/api/docker/projects/v2/token"
DEPOT_REALM_BASE="https://${DEPOT_FQDN}${AUTH_LOCATION_PATH}"

mkdir -p /etc/vmware/wcp/tls /etc/vmware/wcp/nginx/conf.d

iptables -C INPUT -p tcp --dport "${DEPOT_LISTEN_PORT}" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "${DEPOT_LISTEN_PORT}" -j ACCEPT

install -m0644 /tmp/depot-image-proxy.crt /etc/vmware/wcp/tls/depot-image-proxy.crt
install -m0600 /tmp/depot-image-proxy.key /etc/vmware/wcp/tls/depot-image-proxy.key
install -m0644 /tmp/depot-image-proxy-ca.crt /etc/vmware/wcp/tls/depot-image-proxy-ca.crt
rm -f /tmp/depot-image-proxy.crt /tmp/depot-image-proxy.key /tmp/depot-image-proxy-ca.crt

kubectl get managementservices vcf-depot -o jsonpath='{.spec.ports[0].tls.certificateAuthorityChain}' \
    > /etc/vmware/wcp/tls/depot-image-registry-trusted.crt
[[ -s /etc/vmware/wcp/tls/depot-image-registry-trusted.crt ]] || { echo "empty depot CA chain" >&2; exit 1; }

chown nginx:nginx \
    /etc/vmware/wcp/tls/depot-image-proxy.crt \
    /etc/vmware/wcp/tls/depot-image-proxy.key \
    /etc/vmware/wcp/tls/depot-image-registry-trusted.crt

TMP_OUT="$(mktemp)"
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//__AUTH_LOCATION__/${AUTH_LOCATION_PATH}}"
    line="${line//__DEPOT_REALM_BASE__/${DEPOT_REALM_BASE}}"
    line="${line//__DEPOT_HOST__/${DEPOT_HOST}}"
    line="${line//__DEPOT_UPSTREAM__/${DEPOT_UPSTREAM}}"
    line="${line//__DEPOT_LISTEN_PORT__/${DEPOT_LISTEN_PORT}}"
    printf '%s\n' "${line}"
done < /tmp/depot-nginx.tpl > "${TMP_OUT}"
mv -f "${TMP_OUT}" "${NGINX_DEPOT_PROXY_CONF}"
rm -f /tmp/depot-nginx.tpl
chown nginx:nginx "${NGINX_DEPOT_PROXY_CONF}"

kubectl apply -f - <<SVC
apiVersion: v1
kind: Service
metadata:
  name: depot-image-proxy
  namespace: kube-system
spec:
  type: LoadBalancer
  selector:
    component: kubectl-plugin-vsphere
  ports:
    - name: https
      protocol: TCP
      port: 443
      targetPort: ${DEPOT_LISTEN_PORT}
SVC

DEPOT_LB_IP="$(wait_depot_lb_ip)" || {
    echo "ERROR: timed out waiting for depot-image-proxy LoadBalancer ingress IP" >&2
    exit 1
}

mkdir -p "$(dirname "${COREDNS_HOSTS}")"
remove_depot_coredns_manual_block "${COREDNS_HOSTS}" "${DEPOT_FQDN}"
{
    printf '%s\n' "${SCRIPT_HOSTS_MARK}"
    printf '%s %s\n' "${DEPOT_LB_IP}" "${DEPOT_FQDN}"
    printf '%s\n' "${SCRIPT_HOSTS_MARK}"
} >>"${COREDNS_HOSTS}"

chmod 0644 "${COREDNS_HOSTS}"
kubectl -n kube-system rollout restart deployment coredns

if [[ -f "${MANIFEST}" ]]; then
    TMP_M="${MANIFEST}.tmp.$$"
    mv "${MANIFEST}" "${TMP_M}"
    sleep 2
    mv "${TMP_M}" "${MANIFEST}"
else
    echo "WARN: manifest ${MANIFEST} not found; skip bounce" >&2
fi
EOS
}

remote_remove_on_cp() {
    local cp="$1"
    "${SSH_CP[@]}" "root@${cp}" bash -s \
        "${NGINX_DEPOT_PROXY_CONF}" \
        "${MANIFEST}" \
        "${COREDNS_HOSTS}" \
        "${SERVER_SAN_DNS}" \
        "${DEPOT_PROXY_LISTEN_PORT}" \
        <<'EOS'
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NGINX_DEPOT_PROXY_CONF="$1"
MANIFEST="$2"
COREDNS_HOSTS="$3"
DEPOT_FQDN="$4"
DEPOT_LISTEN_PORT="$5"

remove_depot_coredns_manual_block() {
    local f="$1" fqdn="$2"
    [[ -f "$f" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    awk -v fqdn="$fqdn" '
        function t(s) { gsub(/\r/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        t($0) == "# MANUALLY UPDATED BY SCRIPT" {
            first = $0
            if (getline second <= 0) { print first; next }
            if (index(second, fqdn) > 0) {
                if (getline third <= 0) { print first; print second; next }
                if (t(third) == "# MANUALLY UPDATED BY SCRIPT") { next }
                print first; print second; print third; next
            }
            print first; print second; next
        }
        { print }
    ' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

rm -f "${NGINX_DEPOT_PROXY_CONF}"
rm -f \
    /etc/vmware/wcp/tls/depot-image-proxy.crt \
    /etc/vmware/wcp/tls/depot-image-proxy.key \
    /etc/vmware/wcp/tls/depot-image-proxy-ca.crt \
    /etc/vmware/wcp/tls/depot-image-registry-trusted.crt

iptables -D INPUT -p tcp --dport "${DEPOT_LISTEN_PORT}" -j ACCEPT 2>/dev/null || true

remove_depot_coredns_manual_block "${COREDNS_HOSTS}" "${DEPOT_FQDN}"
[[ -f "${COREDNS_HOSTS}" ]] && chmod 0644 "${COREDNS_HOSTS}"
kubectl -n kube-system rollout restart deployment coredns

kubectl delete svc depot-image-proxy -n kube-system --ignore-not-found >/dev/null

if [[ -f "${MANIFEST}" ]]; then
    TMP_M="${MANIFEST}.tmp.$$"
    mv "${MANIFEST}" "${TMP_M}"
    sleep 2
    mv "${TMP_M}" "${MANIFEST}"
else
    echo "WARN: manifest ${MANIFEST} not found; skip static pod bounce" >&2
fi
EOS
}

register_supervisor_registry() {
    local url bodyf status
    url="$(registry_list_url)"
    bodyf="${WORKDIR}/register-depot-registry.json"
    jq -n \
        --arg name "${DEPOT_REGISTRY_NAME}" \
        --argjson default_registry false \
        --arg hostname "${SERVER_SAN_DNS}" \
        --argjson port "${DEPOT_PROXY_SVC_PORT}" \
        --arg username "" \
        --arg password "" \
        --rawfile ca "${WORKDIR}/depot-image-proxy-ca.crt" \
        '{
            name: $name,
            default_registry: $default_registry,
            image_registry: {
                hostname: $hostname,
                port: $port,
                username: $username,
                password: $password,
                certificate_chain: $ca
            }
        }' >"${bodyf}"

    # shellcheck disable=SC2086
    status="$(curl -sS ${VC_CACERT} -o "${WORKDIR}/register.out" -w '%{http_code}' \
        -X POST \
        -H "vmware-api-session-id: ${SESSION_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @"${bodyf}" \
        "${url}")" || die "curl POST container-image-registries failed"

    if [[ "${status}" != "200" && "${status}" != "201" && "${status}" != "204" ]]; then
        log "vCenter response HTTP ${status}:"
        cat "${WORKDIR}/register.out" >&2 || true
        die "Unexpected HTTP status registering container image registry"
    fi
    log "Registered ${DEPOT_REGISTRY_NAME} with supervisor ${SUPERVISOR_ID} (HTTP ${status})"
}

fetch_vc_ca
vc_session
discover_cluster_id_and_float_from_topology
discover_cp_ips

if [[ "${OPERATION}" == "add" ]]; then
    gen_depot_tls
    for cp in "${CP_IPS[@]}"; do
        log "Configuring control plane VM ${cp} ..."
        scp_tls_and_tpl "${cp}"
        remote_install_on_cp "${cp}"
        log "Done control plane VM ${cp}"
    done
    # Re-run over an existing setup: the CA was regenerated above, so replace the old
    # registration (stale certificate_chain) instead of failing on a duplicate POST.
    if [[ -n "$(depot_registry_id_from_list | tr -d '\r\n')" ]]; then
        log "${DEPOT_REGISTRY_NAME} already registered; replacing it with the regenerated CA"
        unregister_depot_registry
    fi
    register_supervisor_registry
elif [[ "${OPERATION}" == "remove" ]]; then
    unregister_depot_registry
    for cp in "${CP_IPS[@]}"; do
        log "Removing depot proxy from control plane VM ${cp} ..."
        remote_remove_on_cp "${cp}"
        log "Done control plane VM ${cp}"
    done
else
    die "Unknown operation: ${OPERATION}"
fi

log "All steps finished (${OPERATION})."
REMOTE
