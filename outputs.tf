output "mgmt_network_id" {
  description = "libvirt network ID for the management network"
  value       = libvirt_network.mgmt.id
}

output "ovs_network_id" {
  description = "libvirt network ID for the OVS trunk network"
  value       = libvirt_network.ovs_trunk.id
}

output "lab_ssh_public_key" {
  description = "SSH public key provisioned into all lab VMs"
  value       = local.lab_ssh_public_key
}
output "kali_mgmt_ip" {
  description = "Management network IP of the Kali scanner VM (for SSH access)"
  value = try(
    libvirt_domain.kali.network_interface[0].addresses[0],
    "DHCP lease not yet available - check with: virsh domifaddr netutil-lab-kali",
  )
}

output "debian_mgmt_ip" {
  description = "Management network IP of the Debian target VM"
  value = try(
    libvirt_domain.debian.network_interface[0].addresses[0],
    "DHCP lease not yet available - check with: virsh domifaddr netutil-lab-debian",
  )
}

output "ubuntu_mgmt_ip" {
  description = "Management network IP of the Ubuntu target VM"
  value = try(
    libvirt_domain.ubuntu.network_interface[0].addresses[0],
    "DHCP lease not yet available - check with: virsh domifaddr netutil-lab-ubuntu",
  )
}

output "dmz_mgmt_ip" {
  description = "Management network IP of the DMZ web VM"
  value = try(
    libvirt_domain.dmz.network_interface[0].addresses[0],
    "DHCP lease not yet available - check with: virsh domifaddr netutil-lab-dmz",
  )
}

output "all_targets" {
  description = "List of all target VM IPs on VLAN 10"
  value = compact([
    var.debian_ip,
    var.ubuntu_ip,
    var.enable_windows ? var.windows_ip : "",
  ])
}

output "windows_mgmt_ip" {
  description = "Management network IP of the Windows target VM"
  value = var.enable_windows ? try(
    libvirt_domain.windows_target[0].network_interface[0].addresses[0],
    "DHCP lease not yet available - check with: virsh domifaddr netutil-lab-windows",
  ) : ""
}

output "cisco_ios_ip" {
  description = "Cisco IOS simulator IP on VLAN 10"
  value       = var.cisco_ios_ip
}

output "cisco_nexus_ip" {
  description = "Cisco Nexus simulator IP on VLAN 10"
  value       = var.cisco_nexus_ip
}
