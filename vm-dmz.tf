# Cloud-init data source combining user-data and network config for DMZ web server
data "cloudinit_config" "dmz" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/cloud-init/dmz-user-data.yaml",
      {
        ssh_public_key = local.lab_ssh_public_key
        dmz_ip         = var.dmz_ip
        domain         = var.domain
      },
    )
    filename = "user-data"
  }
}

# Cloud-init disk
resource "libvirt_cloudinit_disk" "dmz" {
  name           = "${var.lab_name}-dmz-init.iso"
  pool           = libvirt_pool.volumes.name
  user_data      = data.cloudinit_config.dmz.rendered
  meta_data      = ""

  # Prevents cloud-init from generating an IPv6 DHCP stanza for ens4 (OVS trunk),
  # which would cause networking.service to hang on DHCPv6 Solicit until timeout.
  network_config = <<-EOT
  version: 2
  ethernets:
    ens3:
      dhcp4: true
      dhcp6: false
    ens4:
      dhcp4: false
      dhcp6: false
  EOT

  depends_on = [libvirt_pool.volumes]
}

# DMZ web server — isolated on VLAN 30
resource "libvirt_domain" "dmz" {
  name      = "${var.lab_name}-dmz"
  type      = "kvm"
  memory    = var.target_ram_mb
  vcpu      = var.target_vcpu
  autostart = true
  running   = true

  cloudinit = libvirt_cloudinit_disk.dmz.id

  disk {
    volume_id = libvirt_volume.dmz.id
  }

  # Management network — DHCP from libvirt NAT
  network_interface {
    network_id     = libvirt_network.mgmt.id
    hostname       = "dmz-web"
    wait_for_lease = true
  }

  # OVS trunk — VLAN 30 access port (untagged by OVS)
  network_interface {
    network_id = libvirt_network.ovs_trunk.id
    hostname   = "dmz-web"
    mac        = "52:54:00:0d:01:01"
  }

  # Console output for debugging
  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  lifecycle {
    ignore_changes = [network_interface]
  }

  depends_on = [
    libvirt_network.mgmt,
    libvirt_network.ovs_trunk,
    libvirt_cloudinit_disk.dmz,
  ]
}

# Root disk cloned from the cloud image so the base stays pristine
resource "libvirt_volume" "dmz" {
  name   = "${var.lab_name}-dmz.qcow2"
  pool   = libvirt_pool.volumes.name
  source = abspath("${path.module}/${var.images_dir}/debian-12-generic-amd64.qcow2")
  format = "qcow2"

  depends_on = [libvirt_pool.volumes]
}
