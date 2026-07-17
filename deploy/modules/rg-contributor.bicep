// Module deployed at resource group scope to assign Contributor
// on the gallery resource group. Required so the deployment script
// can create/delete the temporary managed disk used for export.

targetScope = 'resourceGroup'

param principalId string
param roleDefinitionId string

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(principalId, roleDefinitionId, resourceGroup().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
