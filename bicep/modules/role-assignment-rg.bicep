// Role assignment helper - scoped to the deployment's resource group.
targetScope = 'resourceGroup'

param principalId      string
param roleDefinitionId string
param assignmentName   string

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  assignmentName
  scope: resourceGroup()
  properties: {
    principalId:      principalId
    principalType:    'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}
