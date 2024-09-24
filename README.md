# Goals

* create global gateway and mesh control-planes via terraform in konnect
* create a multi(2)-zone mesh and a delegated gateway for ingress in local kind clusters
* deploy sample applications (kubectl) and routes (deck) to demonstrate ingress and zone to zone traffic works as expected
* document scenarios/requests to test the traffic


# Ideas for later

* evolve the sample with APIOPS


# Intro & Pre-Requisites

For the example we will be using two local kind clusters where we install the mesh zones and the ingress delegated Gateway. All components will be connected to the Konnect platform.

Make sure the following tools are installed on your machine (authored on mac):
* kind (authored with v0.24.0) and any of the supported runtimes
* cloud-provider-kind via https://github.com/kubernetes-sigs/cloud-provider-kind?tab=readme-ov-file#install
* kumactl (authored with Client: 2.8.3)
* decK (authored wuith v1.39.4 (aca781a))
* terraform


At first we define the number of clusters and names like that `export CLUSTERS="cluster1 cluster2`.
Set environment variables concerning your Konnect identity and endpoint.\
For Terraform:
```
export KONNECT_TOKEN="kpat_xyzxyzxyz"
export KONNECT_SERVER_URL="https://??.api.konghq.com"
```

For decK:
```
export DECK_KONNECT_ADDR="$KONNECT_SERVER_URL"
export DECK_KONNECT_TOKEN="$KONNECT_TOKEN"
export DECK_KONNECT_CONTROL_PLANE_NAME="test-cp"
```

Have a look at the `.envrc-sample` file for reference. Rename it to `.envrc`, fill it out and run `direnv allow` if you are using this tool or source it.

Then run the following steps as described in their respective sections.


# Run cloud-provider-kind

Install cloud-provider-kind as described [here](https://github.com/kubernetes-sigs/cloud-provider-kind?tab=readme-ov-file#install) and execute `sudo cloud-provider-kind` in a seperate terminal to keep it running.

This tool is required to apply external IPs to the LoadBalancer services used in the kind clusters.


# Automatic installation

Run `create.sh` and wait for it to print the LoadBalancer IP (LB_IP). Then head to the test scenarios section to test the installation.

For tearing down all resources run `destroy.sh`.


# Step by step installation

## Create Kind Clusters

Create kind clusters for the two (or more) zones.
```
for cluster in ${=CLUSTERS}; do 
  kind create cluster --name $cluster --config kind-config.yaml &
done
```


## Create Konnect infrastructure (Mesh and Gateway CP) via Terraform

Create the Mesh control plane and gateway control plane via terraform.

```
terraform -chdir=terraform apply
```


## Configure kumactl and apply defaults

Target kumactl to new Mesh control-plane and create a default allow-all MeshTraficPolicy to ensure traffic can flow after enabling mTLS (which is a requirement for multi-zone communication).

```
  kumactl config control-planes add \
  --address "$KONNECT_SERVER_URL/v0/mesh/control-planes/$(tf output -state ./terraform/*.tfstate -raw mesh_id)/api" \
  --name "$(tf output -state ./terraform/*.tfstate -raw mesh_name)" \
  --headers "authorization=Bearer $KONNECT_TOKEN" --overwrite

  kumactl apply -f mesh-global/mtp-allow-all.yaml
  kumactl apply -f mesh-global/mesh-with-mtls.yaml
```


## Connect Mesh Zone to Konnect

Run these commands to install mesh on the clusters and connect them with the control-plane via the configured token.
Token creation is still a non documented API and is not possible via terraform yet. (it is tracked [here](https://github.com/Kong/kong-mesh/issues/6657))

```
for cluster in ${=CLUSTERS}; do 
  TOKEN=$(curl -s -X  POST   "${KONNECT_SERVER_URL}/v0/mesh/control-planes/281aef97-9e88-40dd-b5fd-5de228adbc86/api/provision-zone"\
    -H "Authorization:$KONNECT_TOKEN" \
    -d "{\"name\":\"${cluster}\"}" \
    -H "Content-Type: application/json" | jq -r .token)

  kubectx kind-$cluster
  kubectl create namespace kong-mesh-system
  kubectl create secret generic cp-token   --namespace kong-mesh-system   --type Opaque   --from-literal=token=${TOKEN}
  helm repo add kong-mesh https://kong.github.io/kong-mesh-charts
  helm repo update
  helm upgrade --install -n kong-mesh-system kong-mesh kong-mesh/kong-mesh -f mesh-global/values.yaml --set-string kuma.controlPlane.kdsGlobalAddress=grpcs://${KONNECT_REGION}.mesh.sync.konghq.com:443 --set-string kuma.controlPlane.konnect.cpId=$(tf output -state ./terraform/*.tfstate -raw mesh_id)
done
```


## Install Gateway dataplane and connect to Konnect

Create a secret with the tls certificates for the gateway dataplane to connect to konnect and install it via Helm.

```
kubectl config use-context kind-${${=CLUSTERS}[1]}
kubectl create namespace kong-gw
kubectl label namespace kong-gw kuma.io/sidecar-injection=enabled
kubectl create secret tls kong-cluster-cert -n kong-gw --cert=./terraform/certs/local_gw.crt --key=./terraform/certs/local_gw.key

helm repo add kong https://charts.konghq.com
helm repo update

CP_ENDPOINT=$(tf output -state ./terraform/*.tfstate -raw cp_endpoint) 
CP_TEL_ENDPOINT=$(tf output -state ./terraform/*.tfstate -raw cp_telemetry_endpoint) 
helm upgrade --install kong-mesh-ingress kong/kong -n kong-gw --values ./gateway/values.yaml \
  --set-string  env.cluster_control_plane="$CP_ENDPOINT:443"\
  --set-string  env.cluster_server_name="$CP_ENDPOINT"\
  --set-string env.cluster_telemetry_endpoint="$CP_TEL_ENDPOINT:443"\
  --set-string env.cluster_telemetry_server_name="$CP_TEL_ENDPOINT"
```


## Deploy sample app (mesh demo-app and httpbin)

This install the httpbin application on both clusters under different service names so it can be identified separately. It also installs the [kuma-counter-demo](https://github.com/kumahq/kuma-counter-demo) with a slight [modification](https://github.com/kumahq/kuma-counter-demo/compare/master...dennyh89:kuma-counter-demo:master) regarding respecting `X-Forwarded-Prefix` headers. This consists of a redis in cluster1 and the frontend and API in cluster2 to demonstrate cross zone communication.

for cluster in ${=CLUSTERS}; do 
  kubectl config use-context kind-$cluster
  kubectl apply -f ./$cluster/demo-app.yaml
  kubectl apply -f ./$cluster/httpbin.yaml
done


## Sync Gateway routes

Sync the routes and services declarations to the kong gateways control-plane in konnect via deck.

```
DECK_KONNECT_CONTROL_PLANE_NAME="$(terraform output -state ./terraform/*.tfstate -raw cp_name )" deck gateway sync gateway/deck.yaml
```


# Test the routes

Use these commands to test the folowing scenarios:

* access httbin on cluster1 which tests the ingress gateway (cluster1) and local zone traffic 
* access httbin on cluster2 which tests the ingress gateway (cluster1) and cross zone traffic from cluster1 to cluster 2 via the cluster2 zone ingress
* access the demo-app api/frontend on cluster2 which tests the ingress gateway (cluster1), cross zone traffic to cluster2 (via zone ingress) and back to cluster1 (via zone ingress) to redis

```
LB_IP=$(kubectl --context "kind-${${=CLUSTERS}[1]}" -n kong-gw get svc kong-mesh-ingress-kong-proxy --output jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test ingress to httbin running on cluster1 (where gateway is running)
curl $LB_IP/cluster1/httpbin/headers

# Test ingress to httpbin running on cluster2 (ingress to remote zone)
curl $LB_IP/cluster2/httpbin/headers

# Test kuma-counter-demo with incrementing, reading and resetting the counter
curl -X POST $LB_IP/cluster2/demo-app/increment
curl $LB_IP/cluster2/demo-app/counter
curl -X DELETE $LB_IP/cluster2/demo-app/counter

# Open kuma-counter-demo in the browser: 
echo $LB_IP/cluster2/demo-app | pbcopy
```

# Teardown

Delete clusters

```
for cluster in ${=CLUSTERS}; do 
  kind delete cluster --name $cluster 
done
```

Delete Konnect entities.
```
terraform -chdir=terraform destroy
```

Or run `destroy.sh`.

# Others

## Label a namespace for sidecar injection
```
k label namespace default kuma.io/sidecar-injection=enabled
```
## Run a network debug container
```
kubectl run debug --image nicolaka/netshoot -- sleep 3600
```