variable "nirmata_token" {
  description = "API token for Nirmata"
  type        = string
  sensitive   = true
}

variable "nirmata_url" {
  description = "URL for the Nirmata environment"
  type        = string
  default     = "https://nirmata.io"
}

variable "nirmata_cluster_name" {
  description = "Name of the cluster in Nirmata"
  type        = string
  default     = "eks-cluster"
}

variable "nirmata_cluster_type" {
  description = "Nirmata cluster type"
  type        = string
  default     = "default-addons-type"
}

# Variables for controller deployment (used in second step)
variable "controller_yamls_folder" {
  description = "Path to controller YAML files (obtained after registration)"
  type        = string
  default     = ""
}

variable "controller_ns_count" {
  description = "Number of namespace YAML files"
  type        = number
  default     = 0
}

variable "controller_sa_count" {
  description = "Number of service account YAML files"
  type        = number
  default     = 0
}

variable "controller_crd_count" {
  description = "Number of CRD YAML files"
  type        = number
  default     = 0
}

variable "controller_deployment_count" {
  description = "Number of deployment YAML files"
  type        = number
  default     = 0
} 