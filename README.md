# AKS Anyscale Setup

Automated multi-region Azure Kubernetes Service (AKS) cluster setup configured for Ray workloads with GPU support.

## Overview

This repository provides infrastructure-as-code automation to deploy production-ready AKS clusters across multiple Azure regions. Each cluster is configured with:

* Azure CNI with Overlay networking
* OIDC and Workload Identity for secure authentication
* Azure Blob Storage with BlobFuse2 for persistent storage
* Multiple node pools: system, CPU (on-demand), and GPU (spot instances with T4 and A100 GPUs)
* NGINX Ingress Controller with LoadBalancer
* NVIDIA Device Plugin for GPU workload scheduling
* Anyscale Operator for AI/ML workload orchestration

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- Anyscale CLI installed and authenticated
- Helm 3.x
- `jq` for JSON parsing


## Quick Start

1. Clone the repository:
```bash
git clone <repository-url>
cd aks-anyscale
```

2. (Optional) Configure environment variables:
```bash
export ANYSCALE_CLOUD_NAME="my-cloud-name"
export REGIONS="eastus westus"
export PRIMARY_REGION="eastus"
export SUBSCRIPTION="your-subscription-id"
export RESOURCE_GROUP="my-rg"
```

3. Run the setup script:
```bash
./setup.sh
```

The script will provision all infrastructure including:
- Resource group and Azure Blob Storage with BlobFuse2
- User Assigned Identity with Storage RBAC roles
- Virtual networks with NAT gateways and NSG rules
- AKS clusters with four node pools (system, CPU, T4 GPU, A100 GPU)
- StorageClass and PersistentVolumeClaim for blob storage
- Kubernetes add-ons (NGINX Ingress Controller, NVIDIA Device Plugin)
- Anyscale Operator installation and cloud registration

## Configuration

Default configuration can be overridden via environment variables. See `setup.sh` for all available options.

### Configuration Files

Kubernetes and infrastructure configuration:
- `values_nginx.yaml`: NGINX Ingress Controller settings
- `values_nvidia.yaml`: NVIDIA Device Plugin settings
- `values_anyscale.yaml`: Anyscale Operator custom instance types
- `cloud_resource.yaml`: Template for Anyscale cloud registration
- `storageclass.yaml`: Azure Blob StorageClass template with BlobFuse2
- `pvc.yaml`: PersistentVolumeClaim template for blob storage

## Storage

The setup includes Azure Blob Storage integration with:
- BlobFuse2 protocol for high-performance file system access
- Workload Identity authentication (no storage account keys needed)
- Optimized mount options for caching and performance
- CORS configuration for Anyscale console access
- User Assigned Identity with proper RBAC roles:
  - Storage Blob Data Contributor (read/write data)
  - Storage Account Key Operator Service Role (list keys)

Storage is accessible to Ray workloads through Kubernetes PersistentVolumeClaims.

## Reference

- [Anyscale Documentation](https://docs.anyscale.com/)
- [AKS Documentation](https://learn.microsoft.com/en-us/azure/aks/)
