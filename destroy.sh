#! /bin/bash
IFS=' ' read -r -a CLUSTERS_ARRAY <<< "$CLUSTERS"

# Delete local clusters
for cluster in ${CLUSTERS_ARRAY[@]}; do 
  kind delete cluster --name $cluster 
done


# Delete Control planes for Mesh and Gateway
terraform -chdir=terraform destroy -auto-approve