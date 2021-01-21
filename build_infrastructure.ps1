
# Location of the ACR and AKV is for this example in a separate subscription
$mainSubscription = '45d3970c-1cf3-47f8-86fa-ae717be4baa9'
# $mainSubscription = '065b0ab4-5905-4ce8-bada-275c71fe7696'
$resourceGroup = 'RandoGroup'
$clusterName = 'RandoCluster'

$acrName = 'hwpacrwestus'
$acrResourceGroup = 'hwp-rg-westus-platform'
$acrSubscription = '38f96d71-58a7-433d-885e-673447cf1140'

$keyVaultName = 'hwp-keyvault-s-westus'

# Login to Azure
az login
az account set --subscription $mainSubscription

# Retrieve resource id from the Platform Container Registry
$acrResourceId = az acr show --name $acrName --resource-group $acrResourceGroup --subscription $acrSubscription --query id

# Retrieve the tenant Id from the KeyVault Subscription
$globalTenantId = az account show --query "tenantId"

# Create resource group
az group create --name $resourceGroup --location westus

# Create cluster
az aks create --resource-group $resourceGroup --name $clusterName --node-vm-size Standard_B2ms --generate-ssh-keys --node-count 3 --enable-managed-identity --attach-acr $acrResourceId --enable-cluster-autoscaler --min-count 1 --max-count 10

# Create local configuration file to talk to the AKS Cluster
az aks get-credentials --resource-group $resourceGroup --name $clusterName

# Collect principals and resource group for Managed Identity Role Assignments
$aks = az aks show --resource-group $resourceGroup --name $clusterName | ConvertFrom-Json

# Retrieve Cluster's Managed Identity
$userAssignedIdentity = az resource list -g $aks.nodeResourceGroup --query "[?contains(type, 'Microsoft.ManagedIdentity/userAssignedIdentities')]"  | ConvertFrom-Json
$identity = az identity show -n $userAssignedIdentity.name -g $userAssignedIdentity.resourceGroup | ConvertFrom-Json

# These variables although unused in this script, are necessary to create the Secret Provider and Identity 
$identityName = $identity.name.ToLower()
$identityId = $identity.id
$identityClientId = $identity.clientId

az role assignment create --role "Managed Identity Operator" --assignee $identity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$($aks.nodeResourceGroup)
az role assignment create --role "Virtual Machine Contributor" --assignee $identity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$($aks.nodeResourceGroup)
az role assignment create --role "Managed Identity Operator" --assignee $identity.clientId --scope /subscriptions/$mainSubscription/resourcegroups/$resourceGroup

# Retrieve KeyVault info
$keyVault = az keyvault show -n $keyVaultName  -g $acrResourceGroup --subscription $acrSubscription | ConvertFrom-Json

# Assign reader role for KeyVault to Cluster's Managed Identity
az role assignment create --role "Reader" --assignee $identity.principalId --scope $keyVault.id

# Set Secret Policys for Identity
az keyvault set-policy -n $keyVaultName -g $acrResourceGroup --subscription $acrSubscription --secret-permissions get --spn $identity.clientId

# Add repos and update
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm repo update

# Add helm chart for KeyVault to Kubernetes Secrets driver
# choco upgrade  kubernetes-helm
kubectl create ns csi-driver
helm install csi-azure csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace csi-driver

# Install AD Identity to AKS
kubectl create ns ad-identity
helm install aad-pod-identity aad-pod-identity/aad-pod-identity --namespace ad-identity --set nmi.allowNetworkPluginKubenet=true

# Expand and Apply the Secret Provider Class to the cluster
Get-Content ./SecretProviderClass.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content ./SecretProviderClass.yaml
kubectl apply -f ./SecretProviderClass.yaml

# Expand and Apply the Identity and Binding
Get-Content ./PodIdentityAndBinding.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content ./PodIdentityAndBinding.yaml
kubectl apply -f ./PodIdentityAndBinding.yaml

# Install Istio
# choco install istioctl
istioctl install

# Install Prometheus
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.8/samples/addons/prometheus.yaml

# Configure Istio sidecar injector
kubectl label namespace default istio-injection=enabled

# Install Istio Gateway
kubectl apply -f ./ums/0.1.IstioGateway.yaml

# Install the User Management Service with Secrets
kubectl apply -f ./ums/0.2.UserManagementServiceDeployment.yaml
kubectl rollout status deployment/ums

# Get the information about one of the pods
$umsPod = kubectl get pod -l app=ums -o jsonpath='{.items[0].metadata.name}'

# Verify the secrets are injected as environment variables.
kubectl describe pod/$umsPod
kubectl exec -it $umsPod printenv
kubectl exec -i -t $umsPod -- /bin/bash

# Get the External IP of the Istio Gateway:
$ingressHost = kubectl get svc istio-ingressgateway -n istio-system -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
$ingressPort = kubectl -n istio-system get service istio-ingressgateway -o jsonpath="{.spec.ports[?(@.name=='http2')].port}"
$secureIngressPort = kubectl -n istio-system get service istio-ingressgateway -o jsonpath="{.spec.ports[?(@.name=='https')].port}"
$tcpIngressPort = kubectl -n istio-system get service istio-ingressgateway -o jsonpath="{.spec.ports[?(@.name=='tcp')].port}"
$umsGatewayUrl = "${ingressHost}:${ingressPort}"

# Check the status of the proxys
istioctl proxy-status

# Get the istio ingress pod
$ingressPod = kubectl get pod -l app=istio-ingressgateway -n istio-system -o jsonpath='{.items[0].metadata.name}'
istioctl proxy-config listener $ingressPod  -n istio-system

# Check the traffic routing in the Proxy
istioctl proxy-config route $ingressPod  -n istio-system --name http.80 -o json

# Install flagger
kubectl apply -k github.com/fluxcd/flagger//kustomize/istio

# Install Canary resource
kubectl apply -f ./ums/0.3.CanaryDeployment.yaml
kubectl describe canary/ums
kubectl wait canary/ums --for=condition=promoted

# Test Canary Deployment
kubectl --record deployment.apps/ums set image deployment.v1.apps/ums ums=hwpacrwestus.azurecr.io/staging/user.management:e164d0f145462ea943667428da2ebf28e8483f23

kubectl run curl-tona --image=radial/busyboxplus:curl -i --tty --rm
while true; do sleep 1; curl ums.default.svc.cluster.local:8080/health; echo -e '\n'; done