# Resource Group
resource "azurerm_resource_group" "finbridge" {
  name     = "${var.environment}-rg"
  location = var.location

  tags = {
    environment = var.environment
    created_by  = "terraform"
    purpose     = "storage-replication-lab"
  }
}

# Virtual Network
resource "azurerm_virtual_network" "finbridge" {
  name                = "${var.environment}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.finbridge.location
  resource_group_name = azurerm_resource_group.finbridge.name

  tags = {
    environment = var.environment
  }
}

# Subnet
resource "azurerm_subnet" "finbridge" {
  name                 = "${var.environment}-subnet"
  resource_group_name  = azurerm_resource_group.finbridge.name
  virtual_network_name = azurerm_virtual_network.finbridge.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Network Security Group
resource "azurerm_network_security_group" "finbridge" {
  name                = "${var.environment}-nsg"
  location            = azurerm_resource_group.finbridge.location
  resource_group_name = azurerm_resource_group.finbridge.name

  security_rule {
    name                       = "allow_rdp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow_storage"
    priority                   = 101
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    environment = var.environment
  }
}

# Public IP
resource "azurerm_public_ip" "finbridge" {
  name                = "${var.environment}-pip"
  location            = azurerm_resource_group.finbridge.location
  resource_group_name = azurerm_resource_group.finbridge.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = var.environment
  }
}

# Network Interface
resource "azurerm_network_interface" "finbridge" {
  name                = "${var.environment}-nic"
  location            = azurerm_resource_group.finbridge.location
  resource_group_name = azurerm_resource_group.finbridge.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.finbridge.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.finbridge.id
  }

  tags = {
    environment = var.environment
  }
}

# Associate NSG with Subnet
resource "azurerm_subnet_network_security_group_association" "finbridge" {
  subnet_id                 = azurerm_subnet.finbridge.id
  network_security_group_id = azurerm_network_security_group.finbridge.id
}

# Storage Account (RA-GRS so the lab can read the secondary endpoint during replication checks)
resource "azurerm_storage_account" "finbridge" {
  name                       = replace("${var.environment}sa", "-", "")
  resource_group_name        = azurerm_resource_group.finbridge.name
  location                   = azurerm_resource_group.finbridge.location
  account_tier               = "Standard"
  account_replication_type   = var.storage_replication_type
  https_traffic_only_enabled = true

  # Enable blob versioning for recovery capability
  blob_properties {
    versioning_enabled = true
  }

  tags = {
    environment = var.environment
    purpose     = "replication-lag-testing"
  }
}

# Blob Container
resource "azurerm_storage_container" "finbridge" {
  name                  = "workload-data"
  storage_account_name  = azurerm_storage_account.finbridge.name
  container_access_type = "private"
}

# Windows Virtual Machine
resource "azurerm_windows_virtual_machine" "finbridge" {
  name                = "${var.environment}-vm"
  location            = azurerm_resource_group.finbridge.location
  resource_group_name = azurerm_resource_group.finbridge.name
  size                = "Standard_B2s"

  admin_username = var.vm_admin_username
  admin_password = var.vm_admin_password

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  network_interface_ids = [
    azurerm_network_interface.finbridge.id,
  ]

  tags = {
    environment = var.environment
  }
}

# VM Custom Script Extension - Install storage tools
resource "azurerm_virtual_machine_extension" "finbridge_setup" {
  name                 = "storage-lab-setup"
  virtual_machine_id   = azurerm_windows_virtual_machine.finbridge.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -Command \"[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://aka.ms/dependencyagentwindows','C:\\\\temp\\\\InstallDependencyAgent.exe'); &'C:\\\\temp\\\\InstallDependencyAgent.exe' /S\""
  })
}
