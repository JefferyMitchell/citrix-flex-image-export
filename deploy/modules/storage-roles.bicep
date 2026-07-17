// Module deployed at resource group scope to assign Storage Blob roles
// on the destination storage account. Grants the export identity permission to:
//   - Write VHD and VMGS blobs (Storage Blob Data Contributor)
//   - Generate user-delegation SAS tokens without account key (Storage Blob Delegator)

targetScope = 'resourceGroup'

param principalId string
param storageAccountName string

var storageBlobDataContributorId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDelegatorId       = 'db58b8e5-c6ad-4a2a-8342-4190687cbf4a'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' existing = {
  name: storageAccountName
}

resource storageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(principalId, storageBlobDataContributorId, storageAccount.id)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobDelegator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(principalId, storageBlobDelegatorId, storageAccount.id)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDelegatorId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
