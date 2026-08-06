terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "~> 1.0.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "vmworkstation" {
  user     = var.vmws_user
  password = var.vmws_password
  url      = var.vmws_endpoint
  https    = false
  debug    = false
}

resource "random_id" "lab_suffix" {
  byte_length = 4
}

resource "vmworkstation_vm" "kali_like" {
  sourceid     = var.template_sourceid
  denomination = "kali-like-vm-${random_id.lab_suffix.hex}"
  description  = "VM attaquante Debian avec outils reseau (simule un Kali)"
  path         = "/home/anna/vmware/kali-like-vm-${random_id.lab_suffix.hex}/kali-like-vm-${random_id.lab_suffix.hex}.vmx"
  processors   = 2
  memory       = 2048
}

resource "vmworkstation_vm" "victim" {
  depends_on   = [vmworkstation_vm.kali_like]
  sourceid     = var.template_sourceid
  denomination = "victim-vm-${random_id.lab_suffix.hex}"
  description  = "VM victime exposant un service web vulnerable"
  path         = "/home/anna/vmware/victim-vm-${random_id.lab_suffix.hex}/victim-vm-${random_id.lab_suffix.hex}.vmx"
  processors   = 2
  memory       = 2048
}

resource "null_resource" "provision_kali_like" {
  depends_on = [vmworkstation_vm.kali_like]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      curl -s -u ${var.vmws_user}:${var.vmws_password} -X PUT ${var.vmws_endpoint}/vms/${vmworkstation_vm.kali_like.id}/power -H "Content-Type: application/vnd.vmware.vmw.rest-v1+json" -d 'on'
      IP=""
      for i in $(seq 1 30); do
        IP=$(curl -s -u ${var.vmws_user}:${var.vmws_password} ${var.vmws_endpoint}/vms/${vmworkstation_vm.kali_like.id}/ip | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null || true)
        if [ -n "$IP" ]; then break; fi
        sleep 5
      done
      if [ -z "$IP" ]; then echo "IP introuvable" && exit 1; fi
      echo "IP kali-like-vm : $IP"
      sshpass -p '${var.ssh_password}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${var.ssh_user}@$IP "echo '${var.ssh_password}' | sudo -S apt update && echo '${var.ssh_password}' | sudo -S apt install -y nmap masscan"
    EOT
  }
}

resource "null_resource" "provision_victim" {
  depends_on = [vmworkstation_vm.victim]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      curl -s -u ${var.vmws_user}:${var.vmws_password} -X PUT ${var.vmws_endpoint}/vms/${vmworkstation_vm.victim.id}/power -H "Content-Type: application/vnd.vmware.vmw.rest-v1+json" -d 'on'
      IP=""
      for i in $(seq 1 30); do
        IP=$(curl -s -u ${var.vmws_user}:${var.vmws_password} ${var.vmws_endpoint}/vms/${vmworkstation_vm.victim.id}/ip | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null || true)
        if [ -n "$IP" ]; then break; fi
        sleep 5
      done
      if [ -z "$IP" ]; then echo "IP introuvable" && exit 1; fi
      echo "IP victim-vm : $IP"
      sshpass -p '${var.ssh_password}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${var.ssh_user}@$IP "echo '${var.ssh_password}' | sudo -S apt update && echo '${var.ssh_password}' | sudo -S apt install -y python3"
      sshpass -p '${var.ssh_password}' ssh -f -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${var.ssh_user}@$IP "nohup python3 -m http.server 8080 < /dev/null > /tmp/http.log 2>&1 &"
    EOT
  }
}
