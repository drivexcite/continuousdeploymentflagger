
# Location of the ACR and AKV is for this example in a separate subscription
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

# Retrieve the tenant Id from the KeyVault Subscription
$globalTenantId = az account show --query "tenantId"

# Create resource group
az group create --name $resourceGroup --location westus

# Create cluster
az aks create --resource-group $resourceGroup --name $clusterName --node-vm-size Standard_B2s --generate-ssh-keys --node-count 3 --enable-managed-identity --attach-acr $acrResourceId

# Create local configuration file to talk to the AKS Cluster
az aks get-credentials --resource-group $resourceGroup --name $clusterName

# Add helm chart for KeyVault to Kubernetes Secrets driver
# choco upgrade  kubernetes-helm
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts

kubectl create ns csi-driver
helm install csi-azure csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace csi-driver

# Collect principals and resource group for Managed Identity Role Assignments
$aks = az aks show --resource-group $resourceGroup --name $clusterName | ConvertFrom-Json

# Create role assignments for AKS Managed Identity
az role assignment create --role "Managed Identity Operator" --assignee $aks.identityProfile.kubeletidentity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$($aks.nodeResourceGroup)
az role assignment create --role "Virtual Machine Contributor" --assignee $aks.identityProfile.kubeletidentity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$($aks.nodeResourceGroup)
az role assignment create --role "Managed Identity Operator" --assignee $aks.identityProfile.kubeletidentity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$resourceGroup

# Install AD Identity to AKS
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts

kubectl create ns ad-identity
helm install aad-pod-identity aad-pod-identity/aad-pod-identity --namespace ad-identity --set nmi.allowNetworkPluginKubenet=true

# Retrieve Cluster's Managed Identity
$userAssignedIdentity = az resource list -g $aks.nodeResourceGroup --query "[?contains(type, 'Microsoft.ManagedIdentity/userAssignedIdentities')]"  | ConvertFrom-Json
$identity = az identity show -n $userAssignedIdentity.name -g $userAssignedIdentity.resourceGroup | ConvertFrom-Json

$identityName = $identity.name.ToLower()
$identityId = $identity.id
$identityClientId = $identity.clientId

az role assignment create --role "Managed Identity Operator" --assignee $identity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$($aks.nodeResourceGroup)
az role assignment create --role "Virtual Machine Contributor" --assignee $identity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$($aks.nodeResourceGroup)
az role assignment create --role "Managed Identity Operator" --assignee $identity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$resourceGroup

# These two will fail (may not be necessary)
# az role assignment create --role "Virtual Machine Contributor" --assignee $identity.clientId --scope /subscriptions/$acrSubscription/resourcegroups/acrResourceGroup
# az role assignment create --role "Managed Identity Operator" --assignee $identity.clientId --scope /subscriptions/$acrSubscription/resourcegroups/$acrResourceGroup

# Retrieve KeyVault info
$keyVault = az keyvault show -n $keyVaultName  -g $acrResourceGroup --subscription $acrSubscription | ConvertFrom-Json

# Assign reader role for KeyVault to Cluster's Managed Identity
az role assignment create --role "Reader" --assignee $identity.principalId --scope $keyVault.id

# Set Secret Policys for Identity
az keyvault set-policy -n $keyVaultName -g $acrResourceGroup --subscription $acrSubscription --secret-permissions get --spn $identity.clientId

# Expand and Apply the Secret Provider Class to the cluster
Get-Content .\SecretProviderClass.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content .\SecretProviderClass.yaml
kubectl apply -f .\SecretProviderClass.yaml

# Expand and Apply the Identity and Binding
Get-Content .\PodIdentityAndBinding.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content .\PodIdentityAndBinding.yaml
kubectl apply -f .\PodIdentityAndBinding.yaml

# Install any pod with secrets mounted
kubectl apply -f .\pod.yaml
kubectl describe pod/nginx-secrets-store-inline

# Check the pod to see if it started and if the secrets are mounted
kubectl describe pod/nginx-secrets-store
kubectl exec -it nginx-secrets-store ls /mnt/secrets-store/