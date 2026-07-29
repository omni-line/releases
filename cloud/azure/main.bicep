@description('Omni Line single-VM deploy (Ubuntu + Docker Compose via cloud-init).')
param location string = resourceGroup().location

@description('Admin username for SSH.')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user.')
@secure()
param adminPublicKey string

@description('VM size (~2 vCPU / 4 GiB recommended).')
param vmSize string = 'Standard_B2s'

@description('CIDR allowed to reach SSH and the Omni Line port.')
param allowedCidr string = '0.0.0.0/0'

@description('Host port for the Omni Line UI / API.')
@minValue(1)
@maxValue(65535)
param omniPort int = 8080

@description('Optional semver pin for GHCR images (empty = latest).')
param omniVersion string = ''

@description('Optional public origin override (e.g. https://registry.example.com).')
param omniUrl string = ''

@description('OS disk size in GiB.')
@minValue(30)
param osDiskSizeGb int = 40

@description('Unique suffix for DNS name of the public IP.')
param dnsLabelPrefix string = 'omni-${uniqueString(resourceGroup().id)}'

var cloudInitUrl = 'https://raw.githubusercontent.com/omni-line/releases/main/cloud/cloud-init.sh'
var versionExport = empty(omniVersion) ? '' : 'export OMNI_VERSION=\'${omniVersion}\'\n'
var urlExport = empty(omniUrl) ? '' : 'export OMNI_URL=\'${omniUrl}\'\n'
var bootstrapScript = format('''#!/bin/bash
set -euo pipefail
export OMNI_PORT={0}
export OMNI_DIR=/opt/omni-line
{1}{2}curl -fsSL {3} | bash
''', omniPort, versionExport, urlExport, cloudInitUrl)

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'omni-line-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'SSH'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'OmniLine'
        properties: {
          priority: 1010
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: string(omniPort)
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'omni-line-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabelPrefix
    }
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'omni-line-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.20.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'omni-line-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'omni-line-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'omni-line'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-noble'
        sku: '24_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: osDiskSizeGb
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource customScript 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'omniLineBootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      script: base64(bootstrapScript)
    }
  }
}

output publicIpAddress string = pip.properties.ipAddress
output publicFqdn string = pip.properties.dnsSettings.fqdn
output publicUrl string = empty(omniUrl) ? 'http://${pip.properties.ipAddress}:${omniPort}' : omniUrl
output sshCommand string = 'ssh ${adminUsername}@${pip.properties.ipAddress}'
output docs string = 'https://omniline.app/docs/install/cloud'
