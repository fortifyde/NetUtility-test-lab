provider "libvirt" {
  uri = "qemu:///system"
}

# Storage pool for Terraform-managed VM volumes and cloud-init disks.
# Separate from ./images/ so terraform destroy can always empty and delete
# this pool cleanly. Base images in ./images/ are referenced by file path only.
resource "libvirt_pool" "volumes" {
  name = "${var.lab_name}-volumes"
  type = "dir"
  path = "/var/lib/libvirt/images/${var.lab_name}"
}
# Auto-generate an SSH key pair when no public key is provided
resource "tls_private_key" "lab" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "ED25519"
}

# Write auto-generated private key to disk so external tools (lab-up.sh --deploy-only,
# demo-prep.sh) can use it without reading from Terraform state.
resource "local_file" "lab_ssh_private_key" {
  count           = var.ssh_public_key == "" ? 1 : 0
  content         = tls_private_key.lab[0].private_key_openssh
  filename        = "${path.module}/.lab-ssh-key"
  file_permission = "0600"
}

# Expose the chosen public key for cloud-init user-data
locals {
  lab_ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.lab[0].public_key_openssh
}
