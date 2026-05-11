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
