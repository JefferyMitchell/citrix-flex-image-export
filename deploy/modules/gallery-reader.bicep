// Module deployed at the gallery's resource group to assign Reader on the gallery
// only. Reading the image version (and its definition) is all the export identity
// needs from the gallery: the temporary disk is created in the deployment's own
// resource group.

targetScope = 'resourceGroup'

param principalId string
param galleryName string

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource gallery 'Microsoft.Compute/galleries@2023-07-03' existing = {
  name: galleryName
}

resource galleryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(principalId, readerRoleId, gallery.id)
  scope: gallery
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
