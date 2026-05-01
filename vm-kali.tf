# Kali scanner VM — the attack/assessment platform for NetUtility.
# Connected to both the management network (SSH from host) and the OVS
# trunk (VLANs 10/20/30 for scanning targets).

# Cloud-init user-data
data "cloudinit_config" "kali" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/cloud-init/kali-user-data.yaml",
      {
        ssh_public_key = local.lab_ssh_public_key
        kali_ip        = var.kali_ip
        kali_vlan20_ip = cidrhost(var.vlan20_cidr, 5)
        kali_vlan30_ip = cidrhost(var.vlan30_cidr, 5)
      },
    )
  }
}

# Cloud-init disk
resource "libvirt_cloudinit_disk" "kali" {
  name           = "${var.lab_name}-kali-init.iso"
  pool           = libvirt_pool.lab.name
  user_data      = data.cloudinit_config.kali.rendered
  meta_data      = ""

  depends_on = [libvirt_pool.lab]
}

resource "libvirt_domain" "kali" {
  name    = "${var.lab_name}-kali"
  type    = "kvm"
  memory  = var.kali_ram_mb
  vcpu    = var.kali_vcpu
  running = true

  # Boot from the Kali cloud image
  disk {
    volume_id = libvirt_volume.kali.id
  }

  # Management network — DHCP from libvirt NAT
  network_interface {
    network_id     = libvirt_network.mgmt.id
    hostname       = "kali-scanner"
    wait_for_lease = true
  }

  # OVS trunk — VLAN 10 native, tagged 10/20/30
  network_interface {
    network_id = libvirt_network.ovs_trunk.id
    mac        = "52:54:00:0a:01:01"
    hostname   = "kali-scanner"
  }

  # Cloud-init drive
  cloudinit = libvirt_cloudinit_disk.kali.id

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
    libvirt_cloudinit_disk.kali,
  ]
}

# Kali root disk — cloned from the cloud image so the base stays pristine
resource "libvirt_volume" "kali" {
  name   = "${var.lab_name}-kali.qcow2"
  pool   = libvirt_pool.lab.name
  source = abspath("${path.module}/${var.images_dir}/kali-linux-last-amd64.qcow2")
  format = "qcow2"

  depends_on = [libvirt_pool.lab]
}


# Auto-deploy NetUtility project to Kali VM after cloud-init completes.
# For incremental updates without reprovisioning, use step 6 in the README.
resource "null_resource" "deploy_netutil" {
  depends_on = [libvirt_domain.kali]

  connection {
    type        = "ssh"
    user        = "kali"
    host        = try(libvirt_domain.kali.network_interface[0].addresses[0], "")
    private_key = file(var.ssh_private_key_path)
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null 2>&1 || true",
      "mkdir -p /opt/netutil/bin /opt/netutil/lab/scripts /opt/netutil/lab/tests /opt/netutil/lab/fixtures /opt/netutil/lab/cloud-init",
      "chown -R kali:kali /opt/netutil",
    ]
  }

  provisioner "file" {
    source      = "${var.netutil_source_dir}/netutil"
    destination = "/opt/netutil/netutil"
  }

  provisioner "file" {
    source      = "${var.netutil_source_dir}/netutil-config.json"
    destination = "/opt/netutil/netutil-config.json"
  }

  provisioner "file" {
    source      = "${var.netutil_source_dir}/bin"
    destination = "/opt/netutil"
  }

  provisioner "file" {
    source      = "${var.netutil_source_dir}/scripts"
    destination = "/opt/netutil"
  }
  provisioner "file" {
    source      = "${abspath(path.module)}/scripts"
    destination = "/opt/netutil/lab"
  }

  provisioner "file" {
    source      = "${abspath(path.module)}/tests"
    destination = "/opt/netutil/lab"
  }

  provisioner "file" {
    source      = "${abspath(path.module)}/fixtures"
    destination = "/opt/netutil/lab"
  }

  provisioner "file" {
    source      = "${abspath(path.module)}/cloud-init"
    destination = "/opt/netutil/lab"
  }

  triggers = {
    # Redeploy when the binary or config changes
    netutil_binary = filemd5("${var.netutil_source_dir}/netutil")
    config_file    = filemd5("${var.netutil_source_dir}/netutil-config.json")
  }
}