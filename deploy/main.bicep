// Citrix Flex Image Export
// Exports OS VHD + VMGS from an Azure Compute Gallery image version
// to blob storage and outputs SAS URIs for Citrix Cloud DaaS portal import.
//
// What this deploys:
//   - User-assigned managed identity (runs the export with no stored credentials)
//   - Role assignments: Contributor on gallery RG + Storage Blob roles on dest storage
//   - Azure CLI deployment script that performs the actual export (~10-15 min)
//
// Outputs:
//   vhdUri          — paste into "VHD URI" in Citrix Cloud portal
//   guestDiskUri    — paste into "Guest Disk URI" (Trusted Launch images only)
//   secureBootEnabled / vTPMEnabled — settings to use when registering the image
//   sasExpiry       — when to re-run this deployment to renew the SAS tokens

targetScope = 'resourceGroup'

// ── Parameters ─────────────────────────────────────────────────────────────────

@description('Resource group that contains the Azure Compute Gallery.')
param galleryResourceGroup string

@description('Name of the Azure Compute Gallery.')
param galleryName string

@description('Image definition name in the gallery (e.g. WinServer2025DC).')
param imageDefinition string

@description('Image version to export (e.g. 1.0.0).')
param imageVersion string

@description('Name of the storage account to receive the exported VHD and VMGS blobs. Must already exist.')
param destStorageAccountName string

@description('Resource group of the destination storage account.')
param destStorageAccountResourceGroup string

@description('Container in the destination storage account. Must already exist (default: vhd-output).')
param outputContainer string = 'vhd-output'

@description('Number of hours the output SAS tokens remain valid. Re-run this deployment to renew.')
@minValue(1)
@maxValue(8760)
param sasHours int = 1

@description('Azure region for the deployment script runner. Must support Azure Container Instances.')
param location string = resourceGroup().location

// ── Variables ──────────────────────────────────────────────────────────────────

var scriptName    = 'export-citrix-flex-image'
var identityName  = 'id-${scriptName}'

// Built-in role definition IDs
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

// ── Managed Identity ───────────────────────────────────────────────────────────
// No stored credentials — the export script authenticates using this identity.

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// ── Role: Contributor on gallery resource group ────────────────────────────────
// Required to create/delete the temporary managed disk used during export.

module galleryRgContributor 'modules/rg-contributor.bicep' = {
  name: 'gallery-rg-contributor'
  scope: resourceGroup(galleryResourceGroup)
  params: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: contributorRoleId
  }
}

// ── Roles: Storage Blob Data Contributor + Storage Blob Delegator ─────────────
// Data Contributor: AzCopy writes VHD and VMGS blobs to the destination container.
// Blob Delegator:   generates user-delegation SAS tokens without needing account key.

module storageRoles 'modules/storage-roles.bicep' = {
  name: 'storage-blob-roles'
  scope: resourceGroup(destStorageAccountResourceGroup)
  params: {
    principalId: managedIdentity.properties.principalId
    storageAccountName: destStorageAccountName
  }
}

// ── Deployment Script ──────────────────────────────────────────────────────────
// Runs the export logic inside a temporary Azure Container Instance.
// cleanupPreference: OnSuccess means the container is removed when export succeeds.
// The outputs (vhdUri, guestDiskUri, etc.) survive cleanup in the script resource.

resource exportScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: scriptName
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.55.0'
    timeout: 'PT2H'
    retentionInterval: 'PT4H'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'GALLERY_RESOURCE_GROUP', value: galleryResourceGroup }
      { name: 'GALLERY_NAME',           value: galleryName }
      { name: 'IMAGE_DEFINITION',       value: imageDefinition }
      { name: 'IMAGE_VERSION',          value: imageVersion }
      { name: 'DEST_STORAGE_ACCOUNT',   value: destStorageAccountName }
      { name: 'DEST_RESOURCE_GROUP',    value: destStorageAccountResourceGroup }
      { name: 'OUTPUT_CONTAINER',       value: outputContainer }
      { name: 'SAS_HOURS',              value: string(sasHours) }
    ]
    scriptContent: loadTextContent('export-image.sh')
  }
  dependsOn: [
    galleryRgContributor
    storageRoles
  ]
}

// ── Outputs ────────────────────────────────────────────────────────────────────
// These appear in the Azure portal "Outputs" tab after deployment.
// Copy vhdUri and guestDiskUri into the Citrix Cloud DaaS portal.

@description('Paste into VHD URI when registering the custom image in Citrix Cloud.')
output vhdUri string = exportScript.properties.outputs.vhdUri

@description('Paste into Guest Disk URI when registering the custom image (Trusted Launch images only).')
output guestDiskUri string = exportScript.properties.outputs.guestDiskUri

@description('Enable Secure Boot in Citrix Cloud when registering the image (true for Trusted Launch).')
output secureBootEnabled string = exportScript.properties.outputs.secureBootEnabled

@description('Enable vTPM in Citrix Cloud when registering the image (true for Trusted Launch).')
output vTPMEnabled string = exportScript.properties.outputs.vTPMEnabled

@description('The SAS tokens in the URIs above expire at this time. Re-run this deployment to renew.')
output sasExpiry string = exportScript.properties.outputs.sasExpiry
