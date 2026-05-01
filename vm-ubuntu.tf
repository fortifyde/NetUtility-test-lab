# Cloud-init data for Ubuntu target
data "cloudinit_config" "ubuntu" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/cloud-init/ubuntu-user-data.yaml",
      {
        ssh_public_key     = local.lab_ssh_public_key
        snmp_community_ro = var.snmp_community_ro
        snmp_community_rw = var.snmp_community_rw
        domain            = var.domain
        ubuntu_ip         = var.ubuntu_ip
        vlan20_ip         = cidrhost(var.vlan20_cidr, 20)
      },
    )
    filename = "user-data"
  }
}

# Cloud-init disk
resource "libvirt_cloudinit_disk" "ubuntu" {
  name           = "${var.lab_name}-ubuntu-init.iso"
  pool           = libvirt_pool.lab.name
  user_data      = data.cloudinit_config.ubuntu.rendered
  meta_data      = ""

  depends_on = [libvirt_pool.lab]
}

# Ubuntu 22.04 target VM — corporate + server VLANs
resource "libvirt_domain" "ubuntu" {
  name      = "${var.lab_name}-ubuntu"
  type      = "kvm"
  memory    = var.target_ram_mb
  vcpu      = var.target_vcpu
  running   = true
  autostart = true

  # Boot from the cloud image
  disk {
    volume_id = libvirt_volume.ubuntu.id
  }

  # Management network — DHCP from libvirt NAT
  network_interface {
    network_id     = libvirt_network.mgmt.id
    hostname       = "ubuntu-target"
    wait_for_lease = true
  }

  # OVS trunk — VLAN 10 + 20 tagged
  network_interface {
    network_id = libvirt_network.ovs_trunk.id
    hostname   = "ubuntu-target"
    mac        = "52:54:00:0c:01:01"
  }
  # Cloud-init drive
  cloudinit = libvirt_cloudinit_disk.ubuntu.id

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
    libvirt_cloudinit_disk.ubuntu,
  ]
}

# Root disk cloned from the cloud image so the base stays pristine
resource "libvirt_volume" "ubuntu" {
  name   = "${var.lab_name}-ubuntu.qcow2"
  pool   = libvirt_pool.lab.name
  source = abspath("${path.module}/${var.images_dir}/jammy-server-cloudimg-amd64.img")
  format = "qcow2"

  depends_on = [libvirt_pool.lab]
}
