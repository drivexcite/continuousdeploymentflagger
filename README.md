# Continuous Deployment with Flagger
This repository contains the setup necessary to create a continuous deployment pipeline of a backend service application written in .NET and deployed to a Kubernetes cluster, leveraging services like Azure Key Vault, Azure Container Registry, Azure Service Bus and Azure SQL Database.

The application 

## Secret Management


# Relevant Links (Errors found during configuration of the AD Pod Identity Provider)
[Secure secrets with Key Vault](https://github.com/HoussemDellai/aks-keyvault)
[Securing Secrets in AKS using Key Vault](https://www.youtube.com/watch?v=dAFWrbeA6vQ&list=PLpbcUe4chE79sB7Jg7B4z3HytqUUEwcNE&index=24)
[404 getting assigned identities for pod](https://github.com/Azure/secrets-store-csi-driver-provider-azure/issues/119)
[Help needed configuring aad-pod-identity](https://github.com/Azure/aad-pod-identity/issues/414)
[mic pod has insufficient permissions on AKS](https://github.com/Azure/aad-pod-identity/issues/38)
[MIC compute.VirtualMachineScaleSetsClient#CreateOrUpdate LinkedAuthorizationFailed when AKS node-pool uses a subnet from another resource group](https://github.com/Azure/aad-pod-identity/issues/511)
[Mounting volumes and exporting environment variables for container](https://github.com/Azure/secrets-store-csi-driver-provider-azure/issues/133)
