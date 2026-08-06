variable "vmws_user" {
  description = "Identifiant de l'API vmrest (VMware Workstation)"
  type        = string
}

variable "vmws_password" {
  description = "Mot de passe de l'API vmrest"
  type        = string
  sensitive   = true
}

variable "vmws_endpoint" {
  description = "URL complète de l'API vmrest, incluant le suffixe /api"
  type        = string
  default     = "http://127.0.0.1:8697/api"
}

variable "template_sourceid" {
  description = "ID vmrest de la VM template Debian 12 (récupéré via GET /api/vms)"
  type        = string
}

variable "ssh_user" {
  description = "Utilisateur SSH pour se connecter aux VMs déployées (créé à l'étape 1)"
  type        = string
}

variable "ssh_password" {
  description = "Mot de passe SSH de l'utilisateur standard de la VM"
  type        = string
  sensitive   = true
}
