#!/usr/bin/env bash
set -euo pipefail

source variables.sh

echo "==> Resource Group"
az account set -s "$SUBSCRIPTION"
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo "Resource group $RESOURCE_GROUP already exists"
else
  az group create --name "$RESOURCE_GROUP" --location "$PRIMARY_REGION"
fi

echo "==> Storage Account"
if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "Storage account $STORAGE_ACCOUNT already exists"
else
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$PRIMARY_REGION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false
fi

echo "==> Storage Container"
if az storage container show --name "$STORAGE_CONTAINER" --account-name "$STORAGE_ACCOUNT" &>/dev/null; then
  echo "Storage container $STORAGE_CONTAINER already exists"
else
  az storage container create \
    --name "$STORAGE_CONTAINER" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --public-access off
fi

echo "==> Blob Storage CORS"
CORS_ORIGIN="https://console.anyscale.com"
if az storage cors list \
  --services b \
  --account-name "$STORAGE_ACCOUNT" | jq -e --arg origin "$CORS_ORIGIN" '.[] | select(.AllowedOrigins==$origin and (.AllowedMethods | index("GET")) and .MaxAgeInSeconds==600)' >/dev/null; then
  echo "CORS rule for $CORS_ORIGIN already exists"
else
  az storage cors add \
    --services b \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --origins "$CORS_ORIGIN" \
    --methods GET \
    --allowed-headers "*" \
    --exposed-headers "" \
    --max-age 600
fi

echo "==> User Assigned Identity"
if az identity show -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME" &>/dev/null; then
  echo "User assigned identity $USER_IDENTITY_NAME already exists"
  IDENTITY_JSON=$(az identity show -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME")
else
  IDENTITY_JSON=$(az identity create -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME")
fi
IDENTITY_CLIENT_ID=$(echo "$IDENTITY_JSON" | jq -r '.clientId')
IDENTITY_PRINCIPAL_ID=$(echo "$IDENTITY_JSON" | jq -r '.principalId')
IDENTITY_ID=$(echo "$IDENTITY_JSON" | jq -r '.id')

echo "==> Role Assignment"
STORAGE_ACCOUNT_ID=$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query id -o tsv)
echo "Ensuring role assignment exists for identity $USER_IDENTITY_NAME"
if az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ACCOUNT_ID" &>/dev/null; then
  echo "Role assignment already exists or cannot verify due to conditional access policies"
fi

for REGION in $REGIONS; do
  AKS_CLUSTER_NAME="aks-${REGION}"
  VNET_NAME="${AKS_CLUSTER_NAME}-vnet"
  SUBNET_NAME="aks-nodes"
  NAT_PIP_NAME="${AKS_CLUSTER_NAME}-nat-pip"
  NAT_GW_NAME="${AKS_CLUSTER_NAME}-nat-gw"

  echo "==> VNet for $REGION"
  if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &>/dev/null; then
    echo "VNet $VNET_NAME already exists"
  else
    az network vnet create \
      --location "$REGION" \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VNET_NAME" \
      --address-prefixes "$VNET_CIDR"
  fi

  echo "==> Subnet for $REGION"
  if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" &>/dev/null; then
    echo "Subnet $SUBNET_NAME already exists"
  else
    az network vnet subnet create \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME" \
      --address-prefixes "$SUBNET_CIDR"
  fi

  echo "==> Network Security Group for $REGION"
  NSG_NAME="${VNET_NAME}-${SUBNET_NAME}-nsg"
  if az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" &>/dev/null; then
    echo "NSG $NSG_NAME already exists"
  else
    az network nsg create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$NSG_NAME" \
      --location "$REGION"
  fi

  echo "==> Adding HTTPS Inbound Rule to NSG for $REGION"
  if az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name AllowHttpsInbound &>/dev/null; then
    echo "HTTPS inbound rule already exists"
  else
    az network nsg rule create \
      --resource-group "$RESOURCE_GROUP" \
      --nsg-name "$NSG_NAME" \
      --name AllowHttpsInbound \
      --priority 100 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes '*' \
      --source-port-ranges '*' \
      --destination-address-prefixes '*' \
      --destination-port-ranges 443 \
      --description "Allow HTTPS inbound traffic"
  fi

  echo "==> Associating NSG with subnet for $REGION"
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" &>/dev/null || true

  echo "==> Public IP for $REGION"
  if az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$NAT_PIP_NAME" &>/dev/null; then
    echo "Public IP $NAT_PIP_NAME already exists"
  else
    az network public-ip create \
      --location "$REGION" \
      --resource-group "$RESOURCE_GROUP" \
      --name "$NAT_PIP_NAME" \
      --sku Standard \
      --allocation-method Static
  fi

  echo "==> NAT Gateway for $REGION"
  if az network nat gateway show --resource-group "$RESOURCE_GROUP" --name "$NAT_GW_NAME" &>/dev/null; then
    echo "NAT Gateway $NAT_GW_NAME already exists"
  else
    az network nat gateway create \
      --location "$REGION" \
      --resource-group "$RESOURCE_GROUP" \
      --name "$NAT_GW_NAME" \
      --public-ip-addresses "$NAT_PIP_NAME" \
      --idle-timeout 10
  fi

  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --nat-gateway "$NAT_GW_NAME" &>/dev/null || true

  SUBNET_ID=$(az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" --query id -o tsv)

  echo "==> AKS Cluster (OIDC + Workload Identity + Overlay + NAT outbound) in $REGION"
  if az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" &>/dev/null; then
    echo "AKS cluster $AKS_CLUSTER_NAME already exists"
  else
    az aks create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$AKS_CLUSTER_NAME" \
      --location "$REGION" \
      --tier Standard \
      --kubernetes-version "$AKS_VERSION" \
      --enable-oidc-issuer \
      --enable-workload-identity \
      --network-plugin azure \
      --network-plugin-mode overlay \
      --pod-cidr "$POD_CIDR" \
      --outbound-type userAssignedNATGateway \
      --vnet-subnet-id "$SUBNET_ID" \
      --nodepool-name sys \
      --node-count "$SYSTEM_POOL_COUNT" \
      --node-vm-size "$SYSTEM_POOL_VM_SIZE"
  fi

  echo "==> Federated Credential (ServiceAccount -> Identity) for $REGION"
  OIDC_ISSUER=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)
  FED_CRED_NAME="${AKS_CLUSTER_NAME}-operator-fic"

  if az identity federated-credential show --name "$FED_CRED_NAME" --identity-name "$USER_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    echo "Federated credential $FED_CRED_NAME already exists"
  else
    az identity federated-credential create \
      --name "$FED_CRED_NAME" \
      --identity-name "$USER_IDENTITY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --issuer "$OIDC_ISSUER" \
      --subject "system:serviceaccount:anyscale-operator:anyscale-operator" \
      --audiences "api://AzureADTokenExchange"
  fi

  echo "==> Adding CPU Pool (on-demand) for $REGION"
  if az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" --name cpu &>/dev/null; then
    echo "CPU node pool already exists"
  else
    az aks nodepool add \
      --resource-group "$RESOURCE_GROUP" \
      --cluster-name "$AKS_CLUSTER_NAME" \
      --name cpu \
      --enable-cluster-autoscaler \
      --min-count "$CPU_POOL_MIN_COUNT" \
      --max-count "$CPU_POOL_MAX_COUNT" \
      --node-vm-size "$CPU_POOL_VM_SIZE" \
      --labels node.anyscale.com/capacity-type=ON_DEMAND \
      --node-taints node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule
  fi

  echo "==> Adding T4 Pool (spot) for $REGION"
  if az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" --name t4 &>/dev/null; then
    echo "T4 node pool already exists"
  else
    az aks nodepool add \
      --resource-group "$RESOURCE_GROUP" \
      --cluster-name "$AKS_CLUSTER_NAME" \
      --name t4 \
      --enable-cluster-autoscaler \
      --node-count 0 \
      --min-count "$T4_POOL_MIN_COUNT" \
      --max-count "$T4_POOL_MAX_COUNT" \
      --node-vm-size "$T4_POOL_VM_SIZE" \
      --labels "node.anyscale.com/capacity-type=SPOT" "nvidia.com/gpu.product=NVIDIA-T4" "nvidia.com/gpu.count=1" \
      --priority Spot \
      --node-taints "node.anyscale.com/capacity-type=SPOT:NoSchedule,nvidia.com/gpu=present:NoSchedule,node.anyscale.com/accelerator-type=GPU:NoSchedule"
  fi

  echo "==> Adding A100 Pool (spot) for $REGION"
  if az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" --name a100 &>/dev/null; then
    echo "A100 node pool already exists"
  else
    az aks nodepool add \
      --resource-group "$RESOURCE_GROUP" \
      --cluster-name "$AKS_CLUSTER_NAME" \
      --name a100 \
      --enable-cluster-autoscaler \
      --node-count 0 \
      --min-count "$A100_POOL_MIN_COUNT" \
      --max-count "$A100_POOL_MAX_COUNT" \
      --node-vm-size "$A100_POOL_VM_SIZE" \
      --labels "node.anyscale.com/capacity-type=SPOT" "nvidia.com/gpu.product=NVIDIA-A100" "nvidia.com/gpu.count=8" \
      --priority Spot \
      --node-taints "node.anyscale.com/capacity-type=SPOT:NoSchedule,nvidia.com/gpu=present:NoSchedule,node.anyscale.com/accelerator-type=GPU:NoSchedule"
  fi

  echo "==> Install ingress-controller, device-plugin and anyscale-operator for $REGION"
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --overwrite-existing

  echo "----> Installing nginx ingress controller"
  helm repo add nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update nginx
  helm upgrade ingress-nginx nginx/ingress-nginx \
    --version 4.12.1 \
    --namespace ingress-nginx \
    --values values_nginx.yaml \
    --create-namespace \
    --install

  echo "----> Installing nvidia device plugin"
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin 2>/dev/null || true
  helm repo update nvdp
  helm upgrade nvdp nvdp/nvidia-device-plugin \
    --namespace nvidia-device-plugin \
    --version 0.17.1 \
    --values values_nvidia.yaml \
    --create-namespace \
    --install

  echo "==> Register/Get Anyscale Cloud for $REGION"
  if [[ "$REGION" == "$PRIMARY_REGION" ]]; then
    anyscale cloud register \
      --name "$ANYSCALE_CLOUD_NAME" \
      --region "$REGION" \
      --provider azure \
      --compute-stack k8s \
      --cloud-storage-bucket-name "abfss://${STORAGE_CONTAINER}@${STORAGE_ACCOUNT}.dfs.core.windows.net" \
      --cloud-storage-bucket-endpoint "https://${STORAGE_ACCOUNT}.blob.core.windows.net"
  else
    echo "----> Generating cloud resource config for $REGION"
    CLOUD_RESOURCE_YAML="cloud_resource-${REGION}.yaml"
    sed -e "s/\$REGION/${REGION}/g" \
        -e "s/\${STORAGE_CONTAINER}/${STORAGE_CONTAINER}/g" \
        -e "s/\${STORAGE_ACCOUNT}/${STORAGE_ACCOUNT}/g" \
        -e "s/\$IDENTITY_CLIENT_ID/${IDENTITY_CLIENT_ID}/g" \
        cloud_resource.yaml > "$CLOUD_RESOURCE_YAML"

    echo "----> Generated config saved to $CLOUD_RESOURCE_YAML"
    cat "$CLOUD_RESOURCE_YAML"

    anyscale cloud resource create --cloud "$ANYSCALE_CLOUD_NAME" -f "$CLOUD_RESOURCE_YAML" --skip-verification
  fi

  echo "==> Install Anyscale Operator for $REGION"
  helm repo add anyscale https://anyscale.github.io/helm-charts 2>/dev/null || true
  helm repo update anyscale

  CLOUD_RESOURCE_NAME=k8s-azure-$REGION
  CLOUD_DEPLOYMENT_ID="$(
    anyscale cloud get --name "$ANYSCALE_CLOUD_NAME" | awk -v target="$CLOUD_RESOURCE_NAME" '
      $1=="-" && $2=="cloud_resource_id:" { id=$3 }
      $1=="name:" && $2==target { print id; exit }
    '
  )"
  if [[ -z "${CLOUD_DEPLOYMENT_ID}" ]]; then
    echo "ERROR: Could not find cloud_resource_id for cloud resource name '${CLOUD_RESOURCE_NAME}' in cloud '${ANYSCALE_CLOUD_NAME}'" >&2
    exit 1
  fi

  echo "Installing/updating anyscale-operator with Cloud Deployment ID: $CLOUD_DEPLOYMENT_ID"
  ANYSCALE_CLI_TOKEN=$(cat ~/.anyscale/credentials.json  | jq .cli_token)
  helm upgrade anyscale-operator anyscale/anyscale-operator \
    --set-string global.cloudDeploymentId="$CLOUD_DEPLOYMENT_ID" \
    --set-string global.cloudProvider=azure \
    --set-string global.auth.anyscaleCliToken=$ANYSCALE_CLI_TOKEN \
    --set-string global.auth.iamIdentity="$IDENTITY_CLIENT_ID" \
    --set-string workloads.serviceAccount.name=anyscale-operator \
    -f values_anyscale.yaml \
    --namespace anyscale-operator \
    --version 1.2.1 \
    --create-namespace \
    --install

  echo "==> Outputs for $REGION"
  echo "  AKS Cluster Name: $AKS_CLUSTER_NAME"
  echo "  Anyscale Cloud Name: $ANYSCALE_CLOUD_NAME"
  echo "  Cloud Deployment ID: $CLOUD_DEPLOYMENT_ID"
  echo "  Federated Cred Name: $FED_CRED_NAME"
  echo "  OIDC Issuer: $OIDC_ISSUER"
  echo ""

done

echo ""
echo "========================================================================"
echo "==> All clusters created successfully!"
echo "========================================================================"
echo "Resource Group:   $RESOURCE_GROUP"
echo "Storage Account:  $STORAGE_ACCOUNT"
echo "Blob Container:   $STORAGE_CONTAINER"
echo "Identity Client ID: $IDENTITY_CLIENT_ID"
echo ""
echo "Clusters created in regions: $REGIONS"
echo ""

