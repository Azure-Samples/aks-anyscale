# AKS Anyscale Setup

Automated multi-region Azure Kubernetes Service (AKS) cluster setup configured for Ray workloads with GPU support.

## Overview

This repository provides infrastructure-as-code automation to deploy production-ready AKS clusters across multiple Azure regions. Each cluster is configured with:

* Azure CNI with Overlay networking
* OIDC and Workload Identity for secure authentication
* Three node pools: system, CPU (on-demand), and GPU (spot instances with A100 GPUs)
* NGINX Ingress Controller with LoadBalancer
* NVIDIA Device Plugin for GPU workload scheduling
* Anyscale Operator for AI/ML workload orchestration

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- Anyscale CLI installed with credentials at `~/.anyscale/credentials.json`
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
- Resource group and storage account
- Virtual networks with NAT gateways
- AKS clusters with three node pools
- Kubernetes add-ons (NGINX, NVIDIA Device Plugin)
- Anyscale Operator installation and cloud registration

## Configuration

Default configuration can be overridden via environment variables. See `setup.sh` for all available options.

### Helm Values

Configuration files for Kubernetes components:
- `values_nginx.yaml`: NGINX Ingress Controller settings
- `values_nvidia.yaml`: NVIDIA Device Plugin settings
- `values_anyscale.yaml`: Anyscale Operator custom instance types
- `cloud_resource.yaml`: Template for secondary region registration

## Reference

- [Anyscale Documentation](https://docs.anyscale.com/)
- [AKS Documentation](https://learn.microsoft.com/en-us/azure/aks/)
