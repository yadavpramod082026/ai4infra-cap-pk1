variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "finbridge-storage-lab"
}

variable "vm_admin_username" {
  description = "Windows VM admin username"
  type        = string
  default     = "azureadmin"
}

variable "vm_admin_password" {
  description = "Windows VM admin password"
  type        = string
  sensitive   = true
  # In real scenario, use Azure Key Vault or environment variables
}

variable "storage_replication_type" {
  description = "Storage account replication type (use RAGRS to allow read access to the secondary endpoint during the lab)"
  type        = string
  default     = "RAGRS"
  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.storage_replication_type)
    error_message = "Must be a valid replication type."
  }
}
