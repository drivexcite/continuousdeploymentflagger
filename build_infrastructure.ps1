$mainSubscription = '45d3970c-1cf3-47f8-86fa-ae717be4baa9'
$resourceGroup = 'ContinuousGroup'
$clusterName = 'ContinuousCluster'

$acrName = 'hwpacrwestus'
$acrResourceGroup = 'hwp-rg-westus-platform'
$acrSubscription = '38f96d71-58a7-433d-885e-673447cf1140'

$keyVaultName = 'hwp-keyvault-s-westus'

# Login to Azure
az login

# Configure ACR
# Retrieve resource id from the Platform Container Registry
$acrResourceId = az acr show --name $acrName --resource-group $acrResourceGroup --subscription $acrSubscription --query id

# Create resource group
az account set --subscription $mainSubscription
az group create --name $resourceGroup --location westus

# Create a service principal
# $principalObject = az ad sp create-for-rbac --skip-assignment | ConvertFrom-Json

# Create cluster
# az aks create --resource-group $resourceGroup --name $clusterName --node-vm-size Standard_B2s --generate-ssh-keys --node-count 3 --enable-managed-identity --attach-acr $acrResourceId --service-principal $principalObject.appId --client-secret $principalObject.password
az aks create --resource-group $resourceGroup --name $clusterName --node-vm-size Standard_B2s --generate-ssh-keys --node-count 3 --enable-managed-identity --attach-acr $acrResourceId

# Create local configuration file to talk to the AKS Cluster
az aks get-credentials --resource-group $resourceGroup --name $clusterName

# Assign Kubernetes Dashboard permissions to the cluster
# https://github.com/Azure/AKS/issues/1573#issuecomment-627070128
kubectl create clusterrolebinding kubernetes-dashboard --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard --user=clusterUser

# Add helm chart for KeyVault to Kubernetes Secrets driver
# choco upgrade  kubernetes-helm
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
helm install csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --generate-name

# Enable AKS Managed Identity
# az aks update -g $resourceGroup -n $clusterName --enable-managed-identity

# Collect principals and resource group for Managed Identity Role Assignments
$aksManagedIdentityClientId = az aks show --resource-group $resourceGroup --name $clusterName --query "identityProfile.kubeletidentity.clientId"
$aksClusterNodeResourceGroup = az aks show --resource-group $resourceGroup --name $clusterName --query "nodeResourceGroup" 

# Assign roles to the AKS Managed Identity
az role assignment create --role "Managed Identity Operator"   --assignee $aksManagedIdentityClientId --scope /subscriptions/$mainSubscription/resourcegroups/$resourceGroup
az role assignment create --role "Managed Identity Operator"   --assignee $aksManagedIdentityClientId --scope /subscriptions/$mainSubscription/resourcegroups/$aksClusterNodeResourceGroup
az role assignment create --role "Virtual Machine Contributor" --assignee $aksManagedIdentityClientId --scope /subscriptions/$mainSubscription/resourcegroups/$aksClusterNodeResourceGroup

# Create an AD Identity
$identityName = 'user-assigned-identity'
az identity create -g $resourceGroup -n $identityName

$managedIdentityClientId = az identity show -g $resourceGroup -n $identityName --query "clientId"
$managedIdentityPrincipalId = az identity show -g $resourceGroup -n $identityName --query "principalId"

# Assigned the identity as a Reader in KeyVault
az role assignment create --role "Reader" --assignee $managedIdentityPrincipalId --scope /subscriptions/$acrSubscription/resourceGroups/$acrResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName

az keyvault set-policy --name $keyVaultName --resource-group $acrResourceGroup --subscription $acrSubscription --secret-permissions get --spn $managedIdentityClientId
az keyvault set-policy --name $keyVaultName --resource-group $acrResourceGroup --subscription $acrSubscription --key-permissions get --spn $managedIdentityClientId

# Install AD Identity to AKS
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm install pod-identity aad-pod-identity/aad-pod-identity

# Retrieve the tenant Id from the KeyVault Subscription
$globalTenantId = az account show --query "tenantId"

# Expand and Apply the Secret Provider Class to the cluster
gc .\SecretProviderClass.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | sc .\SecretProviderClass.yaml
kubectl apply -f .\SecretProviderClass.yaml

# Expand and Apply the Identity and Binding
gc .\PodIdentityAndBinding.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | sc .\PodIdentityAndBinding.yaml
kubectl apply -f .\PodIdentityAndBinding.yaml