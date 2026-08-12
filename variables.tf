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
  nullable    = false

  validation {
    condition     = length(var.vm_admin_password) >= 12
    error_message = "VM admin password must be at least 12 characters long."
  }

  validation {
    condition = (
      can(regex("[A-Z]", var.vm_admin_password)) &&
      can(regex("[a-z]", var.vm_admin_password)) &&
      can(regex("[0-9]", var.vm_admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.vm_admin_password))
    )
    error_message = "VM admin password must include uppercase, lowercase, number, and special character."
  }
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
