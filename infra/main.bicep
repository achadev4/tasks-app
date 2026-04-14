targetScope = 'resourceGroup'

@description('Prefix for resource names')
param namePrefix string = 'tasks'

@description('Environment (dev, qa, stg, or prod)')
param environment string = 'prod'

@description('Primary Azure region')
param location string = resourceGroup().location

@description('Azure AD tenant ID (for Key Vault and auth config)')
param tenantId string = subscription().tenantId

@description('Entra app registration client ID for the API (JWT audience for the Function App)')
param apiAppClientId string

@description('SQL connection string for the manually-created Azure SQL free-tier database')
param sqlConnectionString string

var envPrefix = '${namePrefix}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, envPrefix)
var storageName = toLower('${take(envPrefix, 8)}st${uniqueSuffix}')
var funcAppName = '${envPrefix}-func-${uniqueSuffix}'
var swaName = '${envPrefix}-swa-${uniqueSuffix}'
var kvName = 'kv${uniqueString(resourceGroup().id, envPrefix)}'
var lawName = '${envPrefix}-law-${uniqueSuffix}'
var aiName = '${envPrefix}-ai-${uniqueSuffix}'
var blobContainerName = 'task-attachments'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
  }
}

resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: stg
  name: 'default'
}

resource attachmentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: blobContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource deploymentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}


resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
  }
}

resource secretSql 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'SqlConnectionString'
  properties: {
    value: sqlConnectionString
  }
}

var storageConn = 'DefaultEndpointsProtocol=https;AccountName=${stg.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${stg.listKeys().keys[0].value}'

resource secretStorage 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'StorageConnectionString'
  properties: {
    value: storageConn
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${namePrefix}-plan-${uniqueSuffix}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: funcAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${stg.properties.primaryEndpoints.blob}deployments'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 10
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'node'
        version: '20'
      }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConn
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AZURE_AD_TENANT_ID'
          value: tenantId
        }
        {
          name: 'AZURE_AD_AUDIENCE'
          value: apiAppClientId
        }
        {
          name: 'TASKS_BLOB_CONTAINER'
          value: blobContainerName
        }
        {
          name: 'SQL_CONNECTION_STRING'
          value: sqlConnectionString
        }
        {
          name: 'AZURE_STORAGE_CONNECTION_STRING'
          value: storageConn
        }
      ]
    }
  }
  dependsOn: [
    deploymentsContainer
  ]
}

resource diagFunc 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: func
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource swa 'Microsoft.Web/staticSites@2023-12-01' = {
  name: swaName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    provider: 'None'
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
    stagingEnvironmentPolicy: 'Enabled'
  }
}

resource swaBackend 'Microsoft.Web/staticSites/linkedBackends@2023-12-01' = {
  parent: swa
  name: 'functionapp'
  properties: {
    backendResourceId: func.id
    region: location
  }
}

output staticWebAppName string = swa.name
output functionAppName string = func.name
output keyVaultName string = kv.name
output logAnalyticsWorkspaceId string = law.id
output applicationInsightsConnectionString string = appInsights.properties.ConnectionString
output storageAccountName string = stg.name
