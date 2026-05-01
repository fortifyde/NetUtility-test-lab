# NetUtility source (for deploying binaries/scripts to Kali VM)
variable "netutil_source_dir" {
  description = "Path to the NetUtility project root (for deploying binaries/scripts to Kali VM)"
  type        = string
  default     = "../NetUtility"
}

# Lab identification
variable "lab_name" {
  description = "Name prefix for all lab resources"
  type        = string
  default     = "netutil-lab"
}

# Network configuration
variable "bridge_name" {
  description = "OVS bridge name for VLAN trunking (must match setup-ovs.sh)"
  type        = string
  default     = "ovs-br0"
}

variable "mgmt_network" {
  description = "Management network CIDR (NAT, libvirt-managed)"
  type        = string
  default     = "192.168.100.0/24"
}

variable "vlan10_cidr" {
  description = "Corporate VLAN 10 CIDR"
  type        = string
  default     = "10.10.10.0/24"
}

variable "vlan20_cidr" {
  description = "Server VLAN 20 CIDR"
  type        = string
  default     = "10.10.20.0/24"
}

variable "vlan30_cidr" {
  description = "DMZ VLAN 30 CIDR"
  type        = string
  default     = "10.10.30.0/24"
}

# VM IP addresses (static, on VLAN networks)
variable "kali_ip" {
  description = "Kali scanner IP on VLAN 10 (native, trunked 10/20/30)"
  type        = string
  default     = "10.10.10.5"
}

variable "debian_ip" {
  description = "Debian target primary IP on VLAN 10"
  type        = string
  default     = "10.10.10.10"
}

variable "ubuntu_ip" {
  description = "Ubuntu target primary IP on VLAN 10"
  type        = string
  default     = "10.10.10.20"
}

variable "windows_ip" {
  description = "Windows target IP on VLAN 10 (only when enable_windows=true)"
  type        = string
  default     = "10.10.10.30"
}

variable "dmz_ip" {
  description = "DMZ web server IP on VLAN 30"
  type        = string
  default     = "10.10.30.10"
}
# VM resource sizing
variable "kali_ram_mb" {
  description = "RAM allocated to Kali scanner VM in MiB"
  type        = number
  default     = 4096
}

variable "target_ram_mb" {
  description = "RAM allocated to target VMs in MiB"
  type        = number
  default     = 1024
}

variable "kali_vcpu" {
  description = "vCPUs allocated to Kali scanner VM"
  type        = number
  default     = 4
}

variable "target_vcpu" {
  description = "vCPUs allocated to target VMs"
  type        = number
  default     = 2
}

# Images and storage
variable "images_dir" {
  description = "Directory (relative to lab root) for downloaded cloud images"
  type        = string
  default     = "images"
}

# SSH access
variable "ssh_public_key" {
  description = "Pre-existing SSH public key. Leave empty to auto-generate a key pair."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key matching ssh_public_key. Used for auto-deploying files to the Kali VM."
  type        = string
  default     = "~/.ssh/id_rsa"
}

# Lab services
variable "snmp_community_ro" {
  description = "SNMP read-only community string for target VMs"
  type        = string
  default     = "public"
}

variable "snmp_community_rw" {
  description = "SNMP read-write community string for target VMs"
  type        = string
  default     = "private"
}

variable "domain" {
  description = "DNS domain for the lab environment"
  type        = string
  default     = "test.local"
}

# Feature flags
variable "enable_windows" {
  description = "Provision the Windows target VM (requires manual ISO + virtio drivers)"
  type        = bool
  default     = false
}
