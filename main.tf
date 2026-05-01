provider "libvirt" {
  uri = "qemu:///system"
}

# Storage pool for VM disk images
resource "libvirt_pool" "lab" {
  name = "${var.lab_name}-pool"
  type = "dir"

  path = abspath("${path.module}/${var.images_dir}")
}
# Auto-generate an SSH key pair when no public key is provided
resource "tls_private_key" "lab" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "ED25519"
}

# Expose the chosen public key for cloud-init user-data
locals {
  lab_ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.lab[0].public_key_openssh
}
