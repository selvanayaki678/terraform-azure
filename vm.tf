terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.80.0"
    }
  }
}

provider "azurerm" {
    skip_provider_registration = true 
  features {
        virtual_machine {
      delete_os_disk_on_deletion     = true
      graceful_shutdown              = false
      skip_shutdown_and_force_delete = false
    }
  }
}
resource "azurerm_resource_group" "rg" {
  name     = "test-selva-rg"
  location = "East US"
  }

resource "azurerm_virtual_network" "vnet" {
  name                = "test-vnet"
  address_space       = ["10.2.5.0/24"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "vm-subnet" {
  name                 = "sn_10.2.5.0_25"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.2.5.0/26"]
}
resource "azurerm_subnet" "bastion-subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.2.5.64/26"]
}
resource "azurerm_subnet" "fw-subnet" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.2.5.128/26"]
}
#Public ip for Azure firewall
resource "azurerm_public_ip" "pip" {
  name                = "bastion_pub_ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}
#Public Ip for Bastion host
resource "azurerm_public_ip" "bastion_pip" {
  name                = "pub_ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}
#Creating bastion host
resource "azurerm_bastion_host" "bastion" {
  name                = "bastion"
    resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion-subnet.id
    public_ip_address_id = azurerm_public_ip.bastion_pip.id
  }
}
#NIC for linux vm
resource "azurerm_network_interface" "nic" {
  name                = "test-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm-subnet.id
    private_ip_address_allocation = "Dynamic"
    #public_ip_address_id = azurerm_public_ip.pip.id
  }
  #depends_on = [ azurerm_public_ip.pip ]
}
# Creating a Network security group
resource "azurerm_network_security_group" "vm-nsg" {
  name                = "vm-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "nsg_rule" {
  name                        = "allow_22"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.app_sg.id]
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vm-nsg.name
}
#Associating the NSG to the subnet
resource "azurerm_subnet_network_security_group_association" "subnet_nsg_ass" {
  subnet_id                 = azurerm_subnet.vm-subnet.id
  network_security_group_id = azurerm_network_security_group.vm-nsg.id
}
#Creating application security group
resource "azurerm_application_security_group" "app_sg" {
  name                = "vmappsecuritygroup"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

}
#Associating Application security group to VM1
resource "azurerm_network_interface_application_security_group_association" "vm1_app_sg_ass" {
  network_interface_id          = azurerm_network_interface.nic.id
  application_security_group_id = azurerm_application_security_group.app_sg.id
}

// To Generate Private Key
resource "tls_private_key" "rsa_4096" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
resource "azurerm_ssh_public_key" "pub_key" {
  name                = "ssh_public_key"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location 
  public_key          = tls_private_key.rsa_4096.public_key_openssh
}
// Save PEM file locally
resource "local_file" "private_key" {
  content  = tls_private_key.rsa_4096.private_key_pem
  filename = "vm_key"
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "test-linux-vm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]
#  user_data = base64encode("mkdir -p /home/adminuser/test1")
user_data = filebase64("${path.module}/customdata.txt")

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.rsa_4096.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}
# Creating azure firewall policy
resource "azurerm_firewall_policy" "fw-policy" {
  name                = "vm-fw-policy"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  depends_on = [ azurerm_linux_virtual_machine.vm ]
}

resource "azurerm_firewall_policy_rule_collection_group" "fw_policy_rule" {
  name               = "nat-fwpolicy"
  firewall_policy_id = azurerm_firewall_policy.fw-policy.id
  priority           = 500
    nat_rule_collection {
    name     = "nat_rule_collection1"
    priority = 300
    action   = "Dnat"
    rule {
      name                = "allow_80"
      protocols           = ["TCP", "UDP"]
      source_addresses    = ["*"]
      destination_address = azurerm_public_ip.pip.ip_address
      destination_ports   = ["80"]
      translated_address  = azurerm_linux_virtual_machine.vm.private_ip_address
      translated_port     = "80"
    }
  }
  depends_on = [ azurerm_public_ip.pip ]
}
resource "azurerm_firewall" "fw" {
  name                = "vmfirewall"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id = azurerm_firewall_policy.fw-policy.id
  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.fw-subnet.id
    public_ip_address_id = azurerm_public_ip.pip.id
  }
  depends_on = [ azurerm_public_ip.pip ]
}