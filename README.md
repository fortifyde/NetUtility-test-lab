# NetUtility Test Lab

A fully automated QEMU/KVM virtual lab for testing all NetUtility scripts against
real network services. The lab provisions five VMs across three VLANs using
Terraform, libvirt, and Open vSwitch, then runs validation suites from a Kali
scanner against Linux and Windows targets.

## Architecture Overview

```
                    +-------------------------------------------+
                    |          Management Network               |
                    |     192.168.100.0/24 (NAT/DHCP)           |
                    +------+----------+----------+-------------+
                           |          |          |
                +----------+----------+----------+----------+
                |          |          |          |          |
           +----+---+ +---+----+ +---+----+ +---+----+    |
           |  Kali  | | Debian | |Ubuntu  | |  Win   |    |
           |Scanner | |Target 1| |Target 2| |Target  |    |
           +----+---+ +---+----+ +---+----+ +---+----+    |
                |         |          |          |          |
           =====+=========+==========+==========+==========|
           ||        Open vSwitch Bridge              |   ||
           ||   (ovs-br0, trunk ports to all VMs)     |   ||
           ================================================||
                |
           +----+--------------------------------------------+
           |              VLAN 10 - 10.10.10.0/24              |
           |              "Corporate" (untagged on Kali)       |
           +--------------------------------------------------+
           +--------------------------------------------------+
           |              VLAN 20 - 10.10.20.0/24              |
           |              "Servers" (tagged on targets)         |
           +--------------------------------------------------+
           +--------------------------------------------------+
           |              VLAN 30 - 10.10.30.0/24              |
           |              "DMZ" (tagged on dmz-web)             |
           +--------------------------------------------------+
```

### VM Inventory

| VM | Image | Role | VLAN(s) | IP Address(es) | Services | Credentials |
|---|---|---|---|---|---|---|
| kali-scanner | Kali Cloud | Scanner | 10 (native) | 10.10.10.5 | Nmap, all NetUtility tools | kali/kali (SSH key) |
| debian-target | Debian 12 Cloud | Target | 10, 20 | 10.10.10.10, 10.10.20.10 | SSH, SNMP, nginx, bind9 | debian/debian (SSH key) |
| ubuntu-target | Ubuntu 22.04 Cloud | Target | 10, 20 | 10.10.10.20, 10.10.20.20 | SSH, SNMP, Apache+SSL, FTP | ubuntu/ubuntu (SSH key) |
| windows-target | Windows Server Eval | Target | 10 | 10.10.10.30 | RDP, WinRM, SMB, SNMP, IIS | Administrator/P@ssw0rdLab! |
| dmz-web | Debian 12 Cloud | DMZ Web | 30 | 10.10.30.10 | HTTP, HTTPS (multi-cert) | debian/debian (SSH key) |

### Network Layout

| Network | CIDR | Purpose | Notes |
|---|---|---|---|
| Management | 192.168.100.0/24 | Out-of-band access, cloud-init | NAT via libvirt, DHCP |
| VLAN 10 | 10.10.10.0/24 | Corporate | Native/untagged on Kali |
| VLAN 20 | 10.10.20.0/24 | Servers | Tagged on Linux targets |
| VLAN 30 | 10.10.30.0/24 | DMZ | Tagged on dmz-web |

## Prerequisites

### Hardware

- CPU with KVM support (Intel VT-x or AMD-V)
- 16 GB RAM minimum (32 GB recommended)
- 100 GB free disk space for images and VM disks

### Software

- Linux host with KVM enabled
- QEMU/KVM (`qemu-kvm` or `qemu-system-x86`)
- libvirt (`libvirtd`) with the `libvirt` Terraform provider
- Terraform >= 1.5
- Open vSwitch (`openvswitch-switch` or equivalent)
- `curl`, `sha256sum`
- [NetUtility](https://github.com/fortifyde/NetUtility) — cloned separately (see `netutil_source_dir`)

### Prerequisites Check

```bash
# Verify KVM acceleration
kvm-ok

# Verify Open vSwitch
ovs-vsctl --version

# Verify Terraform
terraform version

# Verify libvirt is running
virsh --connect qemu:///system list --all

# Verify available resources
free -h
df -h
```

## Quick Start

```bash
# 1. Download cloud images
./scripts/download-images.sh all

# 2. Set up Open vSwitch bridge (pre-deploy: creates bridge only)
sudo ./scripts/setup-ovs.sh

# 3. Deploy the lab
terraform init
terraform apply -auto-approve

# 4. Configure VLAN tagging on OVS ports (post-deploy)
sudo ./scripts/setup-ovs.sh --post-deploy

# 5. Wait for cloud-init and auto-deploy (5-10 minutes)
#    The NetUtility project is automatically deployed to /opt/netutil on the Kali VM.
#    SSH into the Kali scanner to verify:
ssh kali@$(terraform output -raw kali_mgmt_ip)

# 6. (Optional) Redeploy NetUtility after a hotfix (without rebuilding the lab):
KALI_IP=$(terraform output -raw kali_mgmt_ip)
scp -i ~/.ssh/id_rsa -r \
  ${NETUTIL_SRC:-../NetUtility}/netutil ${NETUTIL_SRC:-../NetUtility}/netutil-config.json \
  ${NETUTIL_SRC:-../NetUtility}/bin ${NETUTIL_SRC:-../NetUtility}/scripts \
  kali@$KALI_IP:/opt/netutil/

# 7. Run the full test suite (from the Kali VM)
cd /opt/netutil && sudo ./lab/tests/run_all.sh

# 8. Collect test outputs and results
./scripts/collect-outputs.sh

# 9. Tear down the lab
terraform destroy -auto-approve

## VM Details

### kali-scanner

The attack/scanner VM running Kali Linux with all NetUtility scripts and
dependencies. It sits on VLAN 10 (native) and can reach all VLANs through the
OVS trunk. All test suites execute from this VM.

- **Image:** Kali Linux cloud (qcow2, converted from disk.raw in tar.xz)
- **Resources:** 4 vCPU, 4 GB RAM
- **VLANs:** 10 (native), trunked to 20 and 30
- **IPs:** 10.10.10.5 (VLAN 10), management IP via DHCP
- **Services:** SSH, Nmap, all NetUtility tools

### debian-target

Primary Linux target running Debian 12 with common network services for
discovery, scanning, and SNMP tests.

- **Image:** Debian 12 Bookworm cloud (qcow2)
- **Resources:** 2 vCPU, 1 GB RAM
- **VLANs:** 10, 20 (tagged)
- **IPs:** 10.10.10.10 (VLAN 10), 10.10.20.10 (VLAN 20)
- **Services:** SSH, SNMP (v2c), nginx, bind9

### ubuntu-target

Secondary Linux target running Ubuntu 22.04 with additional services including
SSL-enabled Apache and FTP for more comprehensive testing.

- **Image:** Ubuntu 22.04 Jammy cloud (qcow2)
- **Resources:** 2 vCPU, 1 GB RAM
- **VLANs:** 10, 20 (tagged)
- **IPs:** 10.10.10.20 (VLAN 10), 10.10.20.20 (VLAN 20)
- **Services:** SSH, SNMP (v2c), Apache (SSL), FTP

### windows-target (optional)

Windows Server target with Active Directory services, RDP, WinRM, SMB, and IIS.
Disabled by default due to the manual ISO requirement.

- **Image:** Windows Server Evaluation ISO
- **Resources:** 2 vCPU, 2 GB RAM
- **VLANs:** 10
- **IPs:** 10.10.10.30 (VLAN 10)
- **Services:** RDP, WinRM, SMB, SNMP, IIS
- **Credentials:** Administrator / P@ssw0rdLab!

### dmz-web

Isolated DMZ web server for testing cross-VLAN scanning and multi-certificate
HTTPS scenarios.

- **Image:** Debian 12 Bookworm cloud (qcow2)
- **Resources:** 2 vCPU, 1 GB RAM
- **VLANs:** 30 (tagged)
- **IPs:** 10.10.30.10 (VLAN 30)
- **Services:** HTTP, HTTPS (multiple certificates)

## Configuration

Copy `terraform.tfvars.example` to `terraform.tfvars` and customize:

```bash
cp terraform.tfvars.example terraform.tfvars
```

### Variables Reference

| Variable | Default | Description |
|---|---|---|
| `netutil_source_dir` | `"../NetUtility"` | Path to the NetUtility project root (for auto-deploy to Kali) |
| `lab_name` | `netutil-lab` | Name prefix for all libvirt resources |
| `bridge_name` | `ovs-br0` | OVS bridge name (must match setup-ovs.sh) |
| `mgmt_network` | `192.168.100.0/24` | Management network CIDR (NAT) |
| `vlan10_cidr` | `10.10.10.0/24` | Corporate VLAN CIDR |
| `vlan20_cidr` | `10.10.20.0/24` | Server VLAN CIDR |
| `vlan30_cidr` | `10.10.30.0/24` | DMZ VLAN CIDR |
| `kali_ip` | `10.10.10.5` | Kali scanner IP on VLAN 10 |
| `debian_ip` | `10.10.10.10` | Debian target IP on VLAN 10 |
| `ubuntu_ip` | `10.10.10.20` | Ubuntu target IP on VLAN 10 |
| `windows_ip` | `10.10.10.30` | Windows target IP on VLAN 10 |
| `dmz_ip` | `10.10.30.10` | DMZ web server IP on VLAN 30 |
| `kali_ram_mb` | `4096` | Kali VM RAM in MiB |
| `target_ram_mb` | `1024` | Target VM RAM in MiB |
| `kali_vcpu` | `4` | Kali VM vCPUs |
| `target_vcpu` | `2` | Target VM vCPUs |
| `images_dir` | `images` | Directory for cloud images (relative to lab root) |
| `ssh_public_key` | `""` | SSH public key (auto-generated if empty) |
| `snmp_community_ro` | `public` | SNMP read-only community string |
| `snmp_community_rw` | `private` | SNMP read-write community string |
| `domain` | `test.local` | DNS domain for the lab |
| `enable_windows` | `false` | Provision the Windows target VM |

### Common Customizations

**Increase Kali RAM for large scans:**
```hcl
kali_ram_mb = 8192
```

**Custom SNMP communities:**
```hcl
snmp_community_ro = "labro"
snmp_community_rw = "labrw"
```

**Use an existing SSH key:**
```hcl
ssh_public_key = "ssh-ed25519 AAAA... user@host"
```

## Windows Target (Optional)

The Windows VM requires manual preparation because the evaluation ISO must be
downloaded through Microsoft's web portal.

### 1. Obtain the Windows Evaluation ISO

Visit [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/) and
download a Windows Server evaluation ISO (e.g., Windows Server 2022).

Save it as `images/windows-server-eval.iso`.

### 2. Download VirtIO Drivers

```bash
./scripts/download-images.sh virtio
```

### 3. Prepare the Autounattend ISO

```bash
sudo ./scripts/prepare-windows.sh
```

This creates an `autounattend.iso` with the unattended installation answer file
and the post-install setup script (`cloud-init/windows/setup-services.ps1`).

### 4. Enable Windows in Terraform

```hcl
# terraform.tfvars
enable_windows = true
```

Then apply:
```bash
terraform apply -auto-approve
```

### 5. Verify

The Windows VM takes 15-20 minutes for unattended installation. Verify with:
```bash
ssh Administrator@10.10.10.30
# or via WinRM
```

## Testing

The test suite runs on the Kali scanner VM and validates all NetUtility scripts
against the lab targets.

### Test Categories

| Category | Script | Description |
|---|---|---|
| discovery | `test_discovery.sh` | Host discovery, ARP scanning, live host detection |
| scanning | `test_scanning.sh` | Port scanning, service detection, OS fingerprinting |
| analysis | `test_analysis.sh` | Result parsing, XML processing, report generation |
| recon | `test_recon.sh` | Reconnaissance scripts, DNS enumeration, banner grabbing |
| config_gathering | `test_config_gathering.sh` | SNMP config collection, running-config retrieval |

### Running Tests

```bash
# Full test suite
cd /opt/netutil && sudo ./lab/tests/run_all.sh

# Specific categories only
./lab/tests/run_all.sh --only discovery --only scanning

# Skip slow categories
./lab/tests/run_all.sh --skip config_gathering

# Individual test script
./lab/tests/test_discovery.sh
```

### Interpreting Results

Tests output TAP (Test Anything Protocol) format:

```
ok 1 - Debian target responds to ping
ok 2 - Nmap TCP scan finds open SSH port
not ok 3 - Windows SNMP community matched
ok 4 # SKIP Windows target unreachable
```

- `ok` -- test passed
- `not ok` -- test failed
- `ok ... # SKIP` -- test skipped (usually target unreachable)

Results are logged to `/tmp/netutil-test/results/` on the Kali VM.

## Troubleshooting

The lab uses `qemu:///system` (system-level libvirt). If your default `virsh`
connects to `qemu:///session`, add `--connect qemu:///system` to virsh commands
or set `LIBVIRT_DEFAULT_URI=qemu:///system` in your shell.

### VM Won't Start

Check libvirt logs and verify resources:

```bash
virsh --connect qemu:///system list --all
virsh --connect qemu:///system domstate <vm_name>
virsh --connect qemu:///system console <vm_name>
journalctl -u libvirtd --since "10 minutes ago"
```

Common causes: insufficient RAM, KVM not enabled, missing cloud image files.

### Cloud-Init Not Completing

Cloud-init provisions services and SSH keys. If targets are unreachable:

```bash
# Inside the VM (via virsh console):
cat /var/log/cloud-init.log
cat /var/log/cloud-init-output.log
cloud-init status
```

Wait 5-10 minutes after `terraform apply`. The first boot runs package installs
and service configuration.

### OVS Bridge Not Working

Verify the bridge and port configuration:

```bash
sudo ./scripts/setup-ovs.sh --status
ovs-vsctl show
ovs-vsctl list-ports ovs-br0
```

Re-create the bridge if needed:

```bash
sudo ./scripts/setup-ovs.sh --force
```

### Target Unreachable from Kali

1. Verify VLAN configuration on the Kali VM:

```bash
# On Kali:
ip addr show
ip route
ping -c 3 10.10.10.10
```

2. Check the OVS trunk port is passing tagged frames:

```bash
ovs-vsctl show
```

3. Verify no host firewall is blocking traffic:

```bash
# On the target:
iptables -L -n
```

### Terraform Provider Issues

The `libvirt` provider can be sensitive to versions. If `terraform init` fails:

```bash
terraform init -upgrade
```

Check the provider version constraint in `versions.tf` and ensure libvirtd is
running:

```bash
systemctl status libvirtd
```

## Cleanup

```bash
# Destroy all VMs and libvirt resources
terraform destroy -auto-approve

# Remove the OVS bridge and ports
sudo ./scripts/setup-ovs.sh --force

# Remove downloaded images (optional)
rm -rf images/

# Remove Terraform state
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform/
```

## File Reference

```
├── README.md                          This file
├── main.tf                            Root Terraform module
├── variables.tf                       Variable definitions
├── outputs.tf                         Output values
├── versions.tf                        Provider version constraints
├── networks.tf                        Network resources (mgmt, OVS trunk)
├── vm-kali.tf                         Kali scanner VM
├── vm-debian.tf                       Debian target VM
├── vm-ubuntu.tf                       Ubuntu target VM
├── vm-dmz.tf                          DMZ web server VM
├── vm-windows.tf                      Windows target VM
├── terraform.tfvars.example           Example variable overrides
├── cloud-init/
│   ├── kali-user-data.yaml            Kali cloud-init user data
│   ├── kali-network-config.yaml       Kali network interfaces
│   ├── debian-user-data.yaml          Debian cloud-init user data
│   ├── debian-network.yaml            Debian network interfaces
│   ├── ubuntu-user-data.yaml          Ubuntu cloud-init user data
│   ├── ubuntu-network.yaml            Ubuntu network interfaces
│   ├── dmz-user-data.yaml             DMZ web server cloud-init user data
│   ├── dmz-network.yaml               DMZ network interfaces
│   └── windows/
│       ├── autounattend.xml           Windows unattended install answer file
│       └── setup-services.ps1         Windows post-install service setup
├── scripts/
│   ├── download-images.sh             Download and verify cloud images
│   ├── setup-ovs.sh                   Create/configure OVS bridge and VLANs
│   ├── prepare-windows.sh             Build autounattend ISO for Windows
│   └── collect-outputs.sh             Collect test results from VMs
├── fixtures/
│   └── network-configs/               Sample device configs for testing
│       ├── cisco_ios/
│       ├── cisco_nexus/
│       ├── hp_comware/
│       ├── hp_provision/
│       ├── aruba_cx/
│       ├── aruba_switch/
│       └── generic/
├── tests/
│   ├── run_all.sh                     Master test orchestrator
│   ├── test_discovery.sh              Host discovery tests
│   ├── test_scanning.sh               Port scanning tests
│   ├── test_analysis.sh               Result analysis tests
│   ├── test_recon.sh                  Reconnaissance tests
│   ├── test_config_gathering.sh       Config gathering tests
│   └── expected/                      Expected output fixtures
│       ├── discovery/
│       ├── scanning/
│       ├── analysis/
│       ├── recon/
│       └── config/
└── images/                            Downloaded cloud images (not in repo)
```
