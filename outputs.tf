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

output "all_targets" {
  description = "List of all target VM IPs on VLAN 10"
  value = compact([
    var.debian_ip,
    var.ubuntu_ip,
    var.enable_windows ? var.windows_ip : "",
  ])
}
