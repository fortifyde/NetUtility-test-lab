# Windows Server target VM — conditional on enable_windows flag.
# Requires: windows-server-eval.iso + autounattend.iso (built by prepare-windows.sh)
# Unattended install takes 20-30 minutes. WinRM will be available after completion.

# ── OS install disk (40 GB) ────────────────────────────────────────────
resource "libvirt_volume" "windows_os" {
  count = var.enable_windows ? 1 : 0

  name   = "${var.lab_name}-windows-os.qcow2"
  pool   = libvirt_pool.lab.name
  format = "qcow2"
  size   = 42949672960 # 40 GiB

  depends_on = [libvirt_pool.lab]
}

# ── Windows target domain ──────────────────────────────────────────────
resource "libvirt_domain" "windows_target" {
  count = var.enable_windows ? 1 : 0

  name      = "${var.lab_name}-windows"
  type      = "kvm"
  memory    = max(var.target_ram_mb, 2048)
  vcpu      = var.target_vcpu
  autostart = true

  # Firmware: UEFI required for Server 2022+
  firmware = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"

  nvram {
    file     = "${path.module}/${var.lab_name}-windows-vars.fd"
    template = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
  }

  # Boot from the Windows installation ISO first
  boot_device {
    dev = ["cdrom"]
  }

  # Suppress OVMF boot menu so install is fully unattended
  xml {
    xslt = <<-EOT
    <xsl:stylesheet version="1.0"
      xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
      <xsl:template match="@*|node()">
        <xsl:copy>
          <xsl:apply-templates select="@*|node()"/>
        </xsl:copy>
      </xsl:template>
      <xsl:template match="/domain/os">
        <xsl:copy>
          <xsl:apply-templates select="@*|node()"/>
          <bootmenu enable='no'/>
        </xsl:copy>
      </xsl:template>
    </xsl:stylesheet>
    EOT
  }

  # ── OS install target disk ───────────────────────────────────────
  disk {
    volume_id = libvirt_volume.windows_os[count.index].id
  }

  # ── Installation media (Windows Server Evaluation ISO) ───────────
  disk {
    file = abspath("${path.module}/${var.images_dir}/windows-server-eval.iso")
  }

  # ── Autounattend.xml ISO (unattended install answer file) ────────
  disk {
    file = abspath("${path.module}/${var.images_dir}/autounattend.iso")
  }

  # ── VirtIO drivers ISO (loaded during WinPE phase) ───────────────
  disk {
    file = abspath("${path.module}/${var.images_dir}/virtio-win.iso")
  }

  # ── Network: management (NAT, DHCP) ─────────────────────────────
  network_interface {
    network_id     = libvirt_network.mgmt.id
    hostname       = "windows-target"
    wait_for_lease = false
  }

  # ── Network: OVS trunk (VLAN 10 for 10.10.10.30) ────────────────
  network_interface {
    network_id = libvirt_network.ovs_trunk.id
    hostname   = "windows-target-vlan"
    mac        = "52:54:00:0e:01:01"
  }

  # ── Console ──────────────────────────────────────────────────────
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

  # Video — VGA required for Windows GUI (Desktop Experience)
  video {
    type = "vga"
  }

  lifecycle {
    ignore_changes = [
      # Disk/ISO images are replaced during reinstall
      disk,
      # Provider resolves network_id to bridge at runtime, causing drift
      network_interface,
    ]
  }

  depends_on = [
    libvirt_network.mgmt,
    libvirt_network.ovs_trunk,
    libvirt_volume.windows_os,
  ]
}

# Send a keypress to bypass Windows "Press any key to boot from CD or DVD" prompt.
# Windows Setup shows this for 3-5 seconds before falling through to next boot device.
# Without a keypress, the unattended install never starts.
resource "null_resource" "windows_boot_keypress" {
  count = var.enable_windows ? 1 : 0

  triggers = {
    domain_id = libvirt_domain.windows_target[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      sleep 5
      virsh --connect qemu:///system send-key ${var.lab_name}-windows KEY_SPACE
      # Send again after a few more seconds in case the first was too early
      sleep 5
      virsh --connect qemu:///system send-key ${var.lab_name}-windows KEY_SPACE
    EOT
  }

  depends_on = [libvirt_domain.windows_target[0]]
}