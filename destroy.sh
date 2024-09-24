#! /bin/zsh

# Delete local clusters
for cluster in ${=CLUSTERS}; do 
  kind delete cluster --name $cluster 
done


# Delete Control planes for Mesh and Gateway
terraform -chdir=terraform destroy -auto-approve