
# Location of the ACR and AKV is for this example in a separate subscription
$mainSubscription = '45d3970c-1cf3-47f8-86fa-ae717be4baa9'
$resourceGroup = 'ContinuousDeploymentGroup'
$clusterName = 'ContiniousCluster'

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
az aks create --resource-group $resourceGroup --name $clusterName --node-vm-size Standard_B2ms --generate-ssh-keys --node-count 2 --enable-managed-identity --attach-acr $acrResourceId --enable-cluster-autoscaler --min-count 1 --max-count 5

# Create local configuration file to talk to the AKS Cluster
az aks get-credentials --resource-group $resourceGroup --name $clusterName

# Collect principals and resource group for Managed Identity Role Assignments
$aks = az aks show --resource-group $resourceGroup --name $clusterName | ConvertFrom-Json

# Retrieve Cluster's Managed Identity
$userAssignedIdentity = az resource list -g $aks.nodeResourceGroup --query "[?contains(type, 'Microsoft.ManagedIdentity/userAssignedIdentities')]"  | ConvertFrom-Json
$identity = az identity show -n $userAssignedIdentity.name -g $userAssignedIdentity.resourceGroup | ConvertFrom-Json

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

# Add helm chart for KeyVault to Kubernetes Secrets driver
# choco upgrade  kubernetes-helm
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts

kubectl create ns csi-driver
helm install csi-azure csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace csi-driver

# Install AD Identity to AKS
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts

kubectl create ns ad-identity
helm install aad-pod-identity aad-pod-identity/aad-pod-identity --namespace ad-identity --set nmi.allowNetworkPluginKubenet=true

# Expand and Apply the Secret Provider Class to the cluster
Get-Content .\SecretProviderClass.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content .\SecretProviderClass.yaml
kubectl apply -f .\SecretProviderClass.yaml

# Expand and Apply the Identity and Binding
Get-Content .\PodIdentityAndBinding.yaml.template | foreach { $ExecutionContext.InvokeCommand.ExpandString($_) } | Set-Content .\PodIdentityAndBinding.yaml
kubectl apply -f .\PodIdentityAndBinding.yaml

# Install the User Management Service with Secrets
kubectl apply -f .ums\0.0.UserManagementServiceSvc.yaml
kubectl apply -f .ums\0.1.ServiceAccount.yaml
kubectl apply -f .ums\0.2.UserManagementServiceDeployment.yaml
kubectl rollout status deployment/ums

# Get the information about one of the pods
$umsPod = kubectl get pod -l app=ums -o jsonpath='{.items[0].metadata.name}'

# Verify the secrets are injected as environment variables.
kubectl describe pod/$umsPod
kubectl exec -it $umsPod printenv
kubectl exec -i -t $umsPod -- /bin/bash

# Check the Cluster from the Outside
#$clusterAddress = kubectl config view -o jsonpath="{'Cluster name\tServer\n'}{range .clusters[*]}{.name}{'__'}{.cluster.server}{'\n'}{end}" | Select-String -Pattern $clusterName -CaseSensitive | Select-Object -first 1 | Foreach-Object { $_.Line.Split('__')[2] }
$clusterAddress = kubectl config view -o jsonpath="{.clusters[?(@.name=='$clusterName')].cluster.server}"
$clusterToken = kubectl get secrets -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='default')].data.token}" | % { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
$clusterResponse = Invoke-WebRequest -Method "GET" -Uri $clusterAddress/api -Headers @{ "Authorization" = "Bearer $clusterToken" } -SkipCertificateCheck

# Install Istio
# choco install istioctl
istioctl install

# Install Prometheus
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.8/samples/addons/prometheus.yaml

# Configure Istio sidecar injector
kubectl label namespace default istio-injection=enabled

# At this point, the deployment has to be redeployed to let the sidecar injector setup the Envoy proxy
kubectl scale deployment.v1.apps/ums --replicas=0
kubectl scale deployment.v1.apps/ums --replicas=3

# Install the Istio Gateway
kubectl apply -f .\ums\0.3.IstioGateway.yaml

# Get the External IP of the Istio Gateway:
$ingressHost = kubectl get svc istio-ingressgateway -n istio-system -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
$ingressPort = kubectl -n istio-system get service istio-ingressgateway -o jsonpath="{.spec.ports[?(@.name=='http2')].port}"
$secureIngressPort = kubectl -n istio-system get service istio-ingressgateway -o jsonpath="{.spec.ports[?(@.name=='https')].port}"
$tcpIngressPort = kubectl -n istio-system get service istio-ingressgateway -o jsonpath="{.spec.ports[?(@.name=='tcp')].port}"
$umsGatewayUrl = "${ingressHost}:${ingressPort}"

# Check the status of the proxys
istioctl proxy-status

# Enable traffic to the UMS
kubectl apply -f .\ums\0.4.UserManagementVirtualService.yaml

# Get the istio ingress pod
$ingressPod = kubectl get pod -l app=istio-ingressgateway -n istio-system -o jsonpath='{.items[0].metadata.name}'
istioctl proxy-config listener $ingressPod  -n istio-system

# Check the traffic routing in the Proxy
istioctl proxy-config route $ingressPod  -n istio-system --name http.80 -o json