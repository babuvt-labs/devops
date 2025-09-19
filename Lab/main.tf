terraform {
  #required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
  backend "azurerm" {
    # Backend configuration will be provided via pipeline parameters
    # Default values - these will be overridden by pipeline
    resource_group_name  = ""
    storage_account_name = ""
    container_name       = ""
    key                  = ""
  }
}

provider "azurerm" {
  features {}
}

# Reference existing resource group instead of creating it
data "azurerm_resource_group" "main" {
  name = "rg-dev"
}

resource "azurerm_virtual_network" "samplevnet" {
  name                = "samplevnet0"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet_a" {
  name                 = "subnet-A"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.samplevnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Test Case 1: Variables with insecure default values (TFLint can check these)
variable "storage_https_enabled" {
  description = "Enable HTTPS traffic only for storage account"
  type        = bool
  default     = false  # TFLint will flag this as insecure default
}

variable "storage_min_tls_version" {
  description = "Minimum TLS version for storage account"
  type        = string
  default     = "TLS1_0"  # TFLint will flag this as outdated/insecure
}

/*
# Test Cases for tfsec - Intentionally insecure configurations
# These will trigger tfsec security findings

# Insecure Storage Account - multiple security issues
resource "azurerm_storage_account" "insecure_storage" {
  name                     = "insecurestorage${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  
  # Security issues that tfsec will catch:
  allow_nested_items_to_be_public = true     # Public access enabled
  https_traffic_only_enabled      = false    # HTTPS not enforced
  min_tls_version                 = "TLS1_0" # Outdated TLS version
  
  # Missing encryption configuration
  # No network access restrictions
}

# Insecure Network Security Group with overly permissive rules
resource "azurerm_network_security_group" "insecure_nsg" {
  name                = "insecure-nsg"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  # Overly permissive inbound rule - allows all traffic from anywhere
  security_rule {
    name                       = "allow_all_inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"        # 0.0.0.0/0 equivalent
    destination_address_prefix = "*"
  }
  
  # SSH open to the world
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "0.0.0.0/0"  # Open to internet
    destination_address_prefix = "*"
  }
}

# Insecure Key Vault
resource "azurerm_key_vault" "insecure_kv" {
  name                = "insecure-kv-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  
  # Security issues:
  enabled_for_disk_encryption     = false  # Disk encryption not enabled
  enabled_for_deployment          = true   # VM deployment enabled (potential risk)
  enabled_for_template_deployment = true   # Template deployment enabled
  enable_rbac_authorization       = false  # RBAC not used
  
  # No network access restrictions
  # No purge protection
}

# Generate random suffix for unique naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Data source for current client configuration
data "azurerm_client_config" "current" {}
*/