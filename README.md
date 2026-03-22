# Purpose

Report **static IPv4 addresses** used by VMs on a **single Nutanix managed subnet**, using Prism Central **Networking v4.2** and **VMM v4.2 AHV** APIs.

Helpful when needing to understand available IP ranges available for NKP.

---

## Requirements

| Component | Version / notes |
|-----------|-----------------|
| **Prism Central** | **2024.3** or later (script uses **v4.2** Networking and VMM AHV endpoints). |
| **Prism Element (AHV)** | **6.8** or later on clusters registered to that PC (VM/NIC payload shape must match current v4.2 AHV VM APIs). |
| **Client host** | `bash`, `curl`, `jq`, `perl` (for CIDR/DHCP static-range math), `base64` (for Basic auth), `kubectl` (optional, with current context pointed at NKP Management Cluster). |
| **Network** | Outbound HTTPS from the machine running the script to Prism Central (typically port **9440**). |

Prism Central Account Permission (Only ONE of these is required):
- VPC Admin
- Prism Admin
- Super Admin
- Network Infra Admin
- Backup Admin

---

## Usage

```bash
./static-scanner.sh -s|--subnet-name <name> [options]
```

| Option | Description |
|--------|-------------|
| `-s`, `--subnet-name` | **Required.** Subnet name as shown in PC (e.g. `vlan402`). |
| `--k8s` | After the VM report, use **kubectl** (current context = NKP **management** cluster) to list **Cluster** CRs. For each **Nutanix** workload cluster whose **control plane** or **node pool** uses that subnet **name**, print the **API VIP** and **service load balancer** address range(s). Requires `kubectl` and cluster-api `Cluster` objects on the mgmt cluster. |
| `-v`, `--verbose` | Print main **stages** on stderr and full **API request/response** bodies (debug mode). |
| `-h`, `--help` | Show help and exit. |

**Prism Central credentials**. 3 Options listed in order of prescendence:

1. **Export** before running:  
   `NUTANIX_ENDPOINT`, `NUTANIX_USER`, `NUTANIX_PASSWORD`
2. **`env.vars`** in the **same directory as the script** (sourced automatically if present), with the three req environment variables.
3. **CLI**: `--pc <url>`, `--user <name>`, `--password '<secret>'`  
   - `--pc` may be `https://fqdn_or_IP:9440` or `fqdn_or_IP:9440`.  

**Example:**

```bash
export NUTANIX_ENDPOINT='https://pc.example.com:9440'
export NUTANIX_USER='admin'
export NUTANIX_PASSWORD='secret'
./static-scanner.sh -s vlan402
```

Or with a local `env.vars` next to the script:

```bash
./static-scanner.sh -s vlan402
```

With Kubernetes / NKP metadata (subnet name must match the Nutanix subnet names in the Cluster spec):

```bash
kubectl config use-context <your-nkp-mgmt-context>
./static-scanner.sh -s vlan402 --k8s
```

---

## Example output

**Normal case (VMs present, some with learned IPs on the subnet):**

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

**With `--k8s`** (example — only clusters whose CP or node pool references this subnet appear):

```text
Kubernetes (NKP) on subnet vlan402:
my-workload-cluster
  |_Control Plane VIP: 10.38.42.50
  |_Node Pool VIP(s): 10.38.42.100-10.38.42.120
```

**No VMs with vNICs on that subnet:**

```text
subnet: vlan402
subnet range: 10.38.42.0/25
DHCP pool: 10.38.42.2-10.38.42.125
static range: 10.38.42.126
Used Static IPs:
  (no VMs returned for this subnet)

SUCCESS: Report complete
```

**VMs exist but no static discovered IPs on that subnet in the API response:**

```text
subnet: vlan402
subnet range: 10.38.42.0/25
DHCP pool: 10.38.42.2-10.38.42.125
static range: 10.38.42.126
Used Static IPs:
  (no static IPs discovered on this subnet))

SUCCESS: Report complete
```

*(Exact CIDR, DHCP pool, static range line, and VM names/IPs depend on your environment.)*

---

## License / support

Typical CYA disclosure: Use at your own risk. Not officially supported script. Always validate against your PC/PE versions in non-production first.
