$mainSubscription = '45d3970c-1cf3-47f8-86fa-ae717be4baa9'
$resourceGroup = 'MyDeploymentGroup'
$clusterName = 'MyContiniousCluster'

$acrName = 'hwpacrwestus'
$acrResourceGroup = 'hwp-rg-westus-platform'
$acrSubscription = '38f96d71-58a7-433d-885e-673447cf1140'

$keyVaultName = 'hwp-keyvault-s-westus'

# Login to Azure
az login

# Retrieve resource id from the Platform Container Registry
$acrResourceId = az acr show --name $acrName --resource-group $acrResourceGroup --subscription $acrSubscription --query id

# Create resource group
az group create --name $resourceGroup --location westus

# Create a service principal
$principalObject = az ad sp create-for-rbac --skip-assignment | ConvertFrom-Json

# Create cluster
az aks create --resource-group $resourceGroup --name $clusterName --node-vm-size Standard_B2s --generate-ssh-keys --node-count 3 --enable-managed-identity --attach-acr $acrResourceId --service-principal $principalObject.appId --client-secret $principalObject.password

# Create local configuration file to talk to the AKS Cluster
az aks get-credentials --resource-group $resourceGroup --name $clusterName

# Add helm chart for KeyVault to Kubernetes Secrets driver
# choco upgrade  kubernetes-helm
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
helm install csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --generate-name

# Collect principals and resource group for Managed Identity Role Assignments
$aksClusterInfo = az aks show --resource-group $resourceGroup --name $clusterName | ConvertFrom-Json

$aksManagedIdentityClientId = $aksClusterInfo.identityProfile.kubeletidentity.clientId
$aksClusterNodeResourceGroup = $aksClusterInfo.nodeResourceGroup

# Assign roles to the AKS Managed Identity
az role assignment create --role "Managed Identity Operator"   --assignee $aksManagedIdentityClientId --scope /subscriptions/$mainSubscription/resourcegroups/$resourceGroup
az role assignment create --role "Managed Identity Operator"   --assignee $aksManagedIdentityClientId --scope /subscriptions/$mainSubscription/resourcegroups/$aksClusterNodeResourceGroup
az role assignment create --role "Virtual Machine Contributor" --assignee $aksManagedIdentityClientId --scope /subscriptions/$mainSubscription/resourcegroups/$aksClusterNodeResourceGroup

# Create an AD Identity
$identityName = 'user-assigned-identity'
$identityInfo = az identity create -g $resourceGroup -n $identityName | ConvertFrom-Json

$managedIdentityClientId = $identityInfo.clientId
$managedIdentityPrincipalId = $identityInfo.principalId

# Assigned the identity as a Reader in KeyVault
az role assignment create --role "Reader" --assignee $managedIdentityPrincipalId --scope /subscriptions/$acrSubscription/resourceGroups/$acrResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName
az role assignment create --role "Reader" --assignee $managedIdentityClientId --scope /subscriptions/$acrSubscription/resourceGroups/$acrResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName
az role assignment create --role "Reader" --assignee $aksManagedIdentityClientId --scope /subscriptions/$acrSubscription/resourceGroups/$acrResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName
az role assignment create --role "Reader" --assignee $principalObject.appId --scope /subscriptions/$acrSubscription/resourceGroups/$acrResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName

az keyvault set-policy --name $keyVaultName --resource-group $acrResourceGroup --subscription $acrSubscription --secret-permissions get --spn $managedIdentityClientId
az keyvault set-policy --name $keyVaultName --resource-group $acrResourceGroup --subscription $acrSubscription --key-permissions get --spn $managedIdentityClientId

az keyvault set-policy --name $keyVaultName --resource-group $acrResourceGroup --subscription $acrSubscription --key-permissions get --spn $aksManagedIdentityClientId
az keyvault set-policy --name $keyVaultName --resource-group $acrResourceGroup --subscription $acrSubscription --key-permissions get --spn $aksManagedIdentityClientId

# Install AD Identity to AKS
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm install pod-identity aad-pod-identity/aad-pod-identity

# Retrieve the tenant Id from the KeyVault Subscription
$globalTenantId = az account show --query "tenantId"

# Expand and Apply the Secret Provider Class to the cluster
Get-Content .\SecretProviderClass.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content .\SecretProviderClass.yaml
kubectl apply -f .\SecretProviderClass.yaml

# Expand and Apply the Identity and Binding
Get-Content .\PodIdentityAndBinding.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content .\PodIdentityAndBinding.yaml
kubectl apply -f .\PodIdentityAndBinding.yaml

# Install any pod with secrets mounted
kubectl apply -f .\pod.yaml
kubectl describe pod/nginx-secrets-store-inline

# Retrieve the managed Node Pool VMSS
$aksNodePoolName = az vmss list -g $aksClusterInfo.nodeResourceGroup --query [0].name -o tsv

# Verify the identities are listed there
az vmss identity show -g $aksClusterInfo.nodeResourceGroup --name $aksNodePoolName