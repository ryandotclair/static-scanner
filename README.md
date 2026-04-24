# Purpose

Two related workflows against **Prism Central**:

1. **Subnet report (default)** — For one **subnet name**, print CIDR, DHCP pool, a derived “static carve-out” line (when `perl` is available), and **VMs whose NICs report guest-learned IPv4** on that subnet (aligned with **learned** addressing, not load-balancer **assigned** VIPs).
2. `**--check` (optional)** — Given one **IPv4**, scan **VM inventory** and report whether any NIC’s contains that address. Returns any matching with **VM name** and **matched subnet**. Use alone for a **global** check, or with `**-s`** to only consider NICs on that subnet.

Useful for NKP prep: see what addresses are already observed on a VLAN, and probe a single address before assigning it.

---

## Requirements


| Component         | Notes                                                                                                                                                                                                                                                           |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Prism Central** | Tested on **v7.3+** PC                                                                                                                                                                                                                                          |
| **Client**        | `bash`, `curl`, `jq`, `base64` (Basic auth). `**perl`** — used for the **subnet report** “static range” line (CIDR minus first DHCP pool); optional (script substitutes a hint if `perl` is missing). `**kubectl`** — only with `**--k8s**` in **report** mode. |
| **Network**       | HTTPS to Prism Central (typically **9440**).                                                                                                                                                                                                                    |


**PC role permissions** (one of these is typically enough): VPC Admin, Prism Admin, Super Admin, Network Infra Admin, or Backup Admin — match your org’s least-privilege policy.

---

## Usage

**Subnet report:**

```bash
./static-scanner.sh -s|--subnet-name <name> [options]
```

**IP check (optional second mode):**

```bash
./static-scanner.sh --check <A.B.C.D> [options]
./static-scanner.sh --check <A.B.C.D> -s <name>   # limit NICs to that subnet only
```


| Option                | Description                                                                                                                                                                                                                                                                                                                                                |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-s`, `--subnet-name` | **Required** for **report** mode. Subnet name as in PC (e.g. `vlan402`). **Optional** with `**--check`**: if set, only NICs on that subnet are considered (faster, answers “free on this segment?”).                                                                                                                                                       |
| `--check` `<IPv4>`    | **Optional.** Scan **all** VMs (paginated v3 `vms/list`) for NICs whose `**ip_endpoint_list[].ip`** equals the address (**any** `type`). Prints **VM name**, **matched subnet** (name + uuid when available), and **endpoint type**. `**--k8s` is not allowed** with `--check`.                                                                            |
| `--k8s`               | **Report mode only.** After the VM section, use **kubectl** (current context = NKP **management** cluster) to list **Cluster** CRs; for each **Nutanix** workload cluster whose **control plane** or **node pool** references that subnet **name**, print **API VIP** and **service LB** range(s). Requires `kubectl` and cluster-api **Cluster** objects. |
| `-v`, `--verbose`     | **Stages** and `**INFO`** on stderr; full **curl** request/response dumps. Expected v3/v4.2 fallback messages use `**verbose_warning`** (stderr **only with `-v`**). With `**--check**`, also prints **VM uuid** on stderr per hit.                                                                                                                        |
| `-h`, `--help`        | Built-in help.                                                                                                                                                                                                                                                                                                                                             |


**Credentials** (**highest takes priority first)**:

1. **CLI:** `--pc`, `--user`, `--password` — explicit flags win over everything else.
2. **Environment variables** set **before** you run the script: `NUTANIX_ENDPOINT`, `NUTANIX_USER`, `NUTANIX_PASSWORD`. These **override** values from `env.vars` if both exist.
3. `**env.vars`** next to the script (sourced if present) — lowest precedence.

---

## Examples

One-liner with flags (no env file):

```bash
./static-scanner.sh -s vlan402 \
  --pc 'https://pc.example.com:9440' --user admin --password 'secret'
```

Using exports (overrides `env.vars` if you have both):

```bash
export NUTANIX_ENDPOINT='https://pc.example.com:9440'
export NUTANIX_USER='admin'
export NUTANIX_PASSWORD='secret'
./static-scanner.sh -s vlan402
```

```bash
kubectl config use-context <nkp-mgmt-context>
./static-scanner.sh -s vlan402 --k8s
```

Global address check (any subnet on this PC):

```bash
./static-scanner.sh --check 10.38.48.140 --pc "https://pc.example.com:9440" --user admin --password 'secret'
```

Same address, only NICs on subnet `secondary` (PC from `env.vars` or env):

```bash
./static-scanner.sh -s secondary --check 10.38.48.140
```

---

## Example output

**Subnet report — VMs with learned IPs:**

```text
subnet: vlan402
subnet range: 10.38.42.0/25
DHCP pool: 10.38.42.2-10.38.42.125
static range: 10.38.42.126
Used Static IPs:
  |_web-01: 10.38.42.126
  |_db-01: 10.38.42.127,10.38.42.128

SUCCESS: Report complete
```

**With `--k8s`:**

```text
NKP Cluster(s) on subnet vlan402:
my-workload-cluster
  |_Control Plane VIP: 10.38.42.50
  |_Node Pool VIP(s): 10.38.42.100-10.38.42.120
```

**No VMs on that subnet (or vNIC list empty):**

```text
Used Static IPs:
  (no VMs returned for this subnet)
```

**VMs present but no learned IPs in API response for that subnet:**

```text
Used Static IPs:
  (no static IPs discovered on this subnet)
```

`**--check` — in use:**

```text
check: 10.38.48.140
Scope: all subnets on this Prism Central — any VM NIC. Note: the same dotted quad can legitimately appear on different L2 segments; this lists every NIC that reports it.
Result: In Use!
  |_ VM: nkp-wlc-a-bnlnd-52smv — subnet: secondary (uuid=f8301000-a5cf-413d-a7ec-cdc9d43db7cb) — endpoint type: LEARNED

SUCCESS: Check complete
```

`**--check` — not found:**

```text
check: 10.38.48.99
…
Result: Not found in use.

SUCCESS: Check complete
```

*(Exact strings depend on your PC and data.)*

---

## Notes

- **Uniqueness:** The same IPv4 string can appear on **different** subnets; `**--check*`* without `**-s**` reports **every** NIC that carries that IP. With `**-s`**, only NICs on the resolved subnet uuid are scanned.

---

## License / support

Use at your own risk. Not an officially supported script. Validate against your PC/PE versions in non-production first.