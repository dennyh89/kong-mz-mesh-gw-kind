#! /bin/bash

IFS=' ' read -r -a CLUSTERS_ARRAY <<< "$CLUSTERS"

for cluster in ${CLUSTERS_ARRAY[@]}; do 
  kind create cluster --name $cluster # --config kind-config.yaml
done

# Create mesh and Gateway Control-plane
terraform -chdir=terraform apply -auto-approve


# create mesh with defaults
kumactl config control-planes add \
--address "$KONNECT_SERVER_URL/v0/mesh/control-planes/$(terraform output -state ./terraform/*.tfstate -raw mesh_id)/api" \
--name "$(terraform output -state ./terraform/*.tfstate -raw mesh_name)" \
--headers "authorization=Bearer $KONNECT_TOKEN" --overwrite

kumactl apply -f mesh-global/mtp-allow-all.yaml
kumactl apply -f mesh-global/mesh-with-mtls.yaml


# Connect zones to Konnect
for cluster in ${CLUSTERS_ARRAY[@]}; do 
  TOKEN=$(curl -s -X  POST   "${KONNECT_SERVER_URL}/v0/mesh/control-planes/$(terraform output -state ./terraform/*.tfstate -raw mesh_id)/api/provision-zone"  -H "Authorization:$KONNECT_TOKEN" -d "{\"name\":\"${cluster}\"}" -H "Content-Type: application/json" | jq -r .token)

  kubectx kind-$cluster
  kubectl create namespace kong-mesh-system
  kubectl create secret generic cp-token   --namespace kong-mesh-system   --type Opaque   --from-literal=token=${TOKEN}
  helm repo add kong-mesh https://kong.github.io/kong-mesh-charts
  helm repo update
  helm upgrade --install -n kong-mesh-system kong-mesh kong-mesh/kong-mesh -f mesh-global/values.yaml --set-string kuma.controlPlane.zone=${cluster}  --set-string kuma.controlPlane.kdsGlobalAddress=grpcs://${KONNECT_REGION}.mesh.sync.konghq.com:443 --set-string kuma.controlPlane.konnect.cpId=$(terraform output -state ./terraform/*.tfstate -raw mesh_id)
done


# install Gateway for ingress on first cluster
kubectl config use-context kind-${CLUSTERS_ARRAY[0]}
kubectl create namespace kong-gw
kubectl label namespace kong-gw kuma.io/sidecar-injection=enabled
kubectl create secret tls kong-cluster-cert -n kong-gw --cert=./terraform/certs/local_gw.crt --key=./terraform/certs/local_gw.key

helm repo add kong https://charts.konghq.com
helm repo update

CP_ENDPOINT=$(terraform output -state ./terraform/*.tfstate -raw cp_endpoint) 
CP_TEL_ENDPOINT=$(terraform output -state ./terraform/*.tfstate -raw cp_telemetry_endpoint) 
helm upgrade --install kong-mesh-ingress kong/kong -n kong-gw --values ./gateway/values.yaml \
  --set-string  env.cluster_control_plane="$CP_ENDPOINT:443"\
  --set-string  env.cluster_server_name="$CP_ENDPOINT"\
  --set-string env.cluster_telemetry_endpoint="$CP_TEL_ENDPOINT:443"\
  --set-string env.cluster_telemetry_server_name="$CP_TEL_ENDPOINT"


# Create sample app (mesh demo-app and httpbin)
for cluster in ${CLUSTERS_ARRAY[@]}; do 
  kubectl config use-context kind-$cluster
  kubectl apply -f ./$cluster/demo-app.yaml
  kubectl apply -f ./$cluster/httpbin.yaml
done


# Sync Gateway routes
DECK_KONNECT_CONTROL_PLANE_NAME="$(terraform output -state ./terraform/*.tfstate -raw cp_name )" deck gateway sync gateway/deck.yaml

export LB_IP=$(kubectl --context "kind-${CLUSTERS_ARRAY[0]}" -n kong-gw get svc kong-mesh-ingress-kong-proxy --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Export LB_IP: export LB_IP=$LB_IP"
