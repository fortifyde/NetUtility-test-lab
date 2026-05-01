# Cloud-init data for Debian target
data "cloudinit_config" "debian" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/cloud-init/debian-user-data.yaml",
      {
        snmp_community_ro = var.snmp_community_ro
        snmp_community_rw = var.snmp_community_rw
        domain            = var.domain
        ssh_public_key     = local.lab_ssh_public_key
        debian_ip          = var.debian_ip
        vlan20_ip          = cidrhost(var.vlan20_cidr, 10)
      },
    )
    filename = "user-data"
  }
}

# Cloud-init disk
resource "libvirt_cloudinit_disk" "debian" {
  name           = "${var.lab_name}-debian-init.iso"
  pool           = libvirt_pool.lab.name
  user_data      = data.cloudinit_config.debian.rendered
  meta_data      = ""

  depends_on = [libvirt_pool.lab]
}

resource "libvirt_domain" "debian" {
  name      = "${var.lab_name}-debian"
  type      = "kvm"
  memory    = var.target_ram_mb
  vcpu      = var.target_vcpu
  autostart = true
  cloudinit = libvirt_cloudinit_disk.debian.id

  disk {
    volume_id = libvirt_volume.debian.id
  }

  network_interface {
    network_id     = libvirt_network.mgmt.id
    hostname       = "debian-target"
    wait_for_lease = true
  }

  network_interface {
    network_id = libvirt_network.ovs_trunk.id
    hostname   = "debian-target"
    mac        = "52:54:00:0b:01:01"
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  lifecycle {
    ignore_changes = [network_interface]
  }

  depends_on = [
    libvirt_network.mgmt,
    libvirt_cloudinit_disk.debian,
  ]
}

# Root disk cloned from the cloud image so the base stays pristine
resource "libvirt_volume" "debian" {
  name   = "${var.lab_name}-debian.qcow2"
  pool   = libvirt_pool.lab.name
  source = abspath("${path.module}/${var.images_dir}/debian-12-generic-amd64.qcow2")
  format = "qcow2"

  depends_on = [libvirt_pool.lab]
}
