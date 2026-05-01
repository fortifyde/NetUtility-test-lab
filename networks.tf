# Management network — fully managed by libvirt (NAT)
resource "libvirt_network" "mgmt" {
  name      = "${var.lab_name}-mgmt"
  autostart = true
  mode      = "nat"
  domain    = var.domain

  dns {
    enabled = true
  }

  addresses = ["${var.mgmt_network}"]
  dhcp {
    enabled = true
  }
}

# OVS-backed trunk network for inter-VM VLAN traffic.
# VMs tag their own traffic via cloud-init 802.1q subinterfaces.
# Requires: OVS bridge created by setup-ovs.sh BEFORE terraform apply.
resource "libvirt_network" "ovs_trunk" {
  name      = "${var.lab_name}-ovs"
  mode      = "bridge"
  autostart = true
  bridge    = var.bridge_name

  xml {
    xslt = <<-EOT
    <xsl:stylesheet version="1.0"
      xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
      <xsl:template match="@*|node()">
        <xsl:copy>
          <xsl:apply-templates select="@*|node()"/>
        </xsl:copy>
      </xsl:template>
      <xsl:template match="/network">
        <network>
          <name><xsl:value-of select="name"/></name>
          <forward mode="bridge"/>
          <bridge name="${var.bridge_name}"/>
          <virtualport type="openvswitch"/>
        </network>
      </xsl:template>
    </xsl:stylesheet>
    EOT
  }
}
