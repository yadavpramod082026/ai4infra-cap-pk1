output "resource_group_name" {
  value = azurerm_resource_group.finbridge.name
}

output "vm_public_ip" {
  value = azurerm_public_ip.finbridge.ip_address
}

output "vm_name" {
  value = azurerm_windows_virtual_machine.finbridge.name
}

output "storage_account_name" {
  value = azurerm_storage_account.finbridge.name
}

output "storage_account_id" {
  value = azurerm_storage_account.finbridge.id
}

output "storage_container_name" {
  value = azurerm_storage_container.finbridge.name
}

output "storage_primary_blob_endpoint" {
  value = azurerm_storage_account.finbridge.primary_blob_endpoint
}

output "storage_secondary_blob_endpoint" {
  value = azurerm_storage_account.finbridge.secondary_blob_endpoint
}
