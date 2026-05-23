data "cloudinit_config" "cisco_ios" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/cloud-init/cisco-ios-user-data.yaml",
      {
        ssh_public_key = local.lab_ssh_public_key
        cisco_ios_ip   = var.cisco_ios_ip
        fixtures = {
          for f in fileset("${path.module}/fixtures/network-configs/cisco_ios", "*.txt") :
          f => base64encode(file("${path.module}/fixtures/network-configs/cisco_ios/${f}"))
        }
      },
    )
    filename = "user-data"
  }
}

resource "libvirt_cloudinit_disk" "cisco_ios" {
  name       = "${var.lab_name}-cisco-ios-init.iso"
  pool       = libvirt_pool.volumes.name
  user_data  = data.cloudinit_config.cisco_ios.rendered
  meta_data  = ""

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

resource "libvirt_volume" "cisco_ios" {
  name   = "${var.lab_name}-cisco-ios.qcow2"
  pool   = libvirt_pool.volumes.name
  source = abspath("${path.module}/${var.images_dir}/debian-12-generic-amd64.qcow2")
  format = "qcow2"

  depends_on = [libvirt_pool.volumes]
}

resource "libvirt_domain" "cisco_ios" {
  name      = "${var.lab_name}-cisco-ios"
  type      = "kvm"
  memory    = 256
  vcpu      = 1
  autostart = true
  cloudinit = libvirt_cloudinit_disk.cisco_ios.id

  disk {
    volume_id = libvirt_volume.cisco_ios.id
  }

  network_interface {
    network_id     = libvirt_network.mgmt.id
    hostname       = "cisco-ios-sim"
    wait_for_lease = true
  }

  network_interface {
    network_id = libvirt_network.ovs_trunk.id
    hostname   = "cisco-ios-sim"
    mac        = "52:54:00:10:01:01"
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
    libvirt_cloudinit_disk.cisco_ios,
  ]
}
