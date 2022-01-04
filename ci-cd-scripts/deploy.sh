#!/usr/bin/env bash

if kubectl get namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"; then
  echo "Namespace ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} found!"
else
  kubectl create namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE";
fi

if kubectl get secret -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$IMAGE_PULL_SECRET_NAME"; then
  echo "Image pull secret ${IMAGE_PULL_SECRET_NAME} found!"
else
  if [[ -n "$BREAK_GLASS" ]]; then
    kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $IMAGE_PULL_SECRET_NAME
  namespace: $IBMCLOUD_IKS_CLUSTER_NAMESPACE
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(jq .parameters.docker_config_json /config/artifactory)
EOF
  else
    kubectl create secret docker-registry \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --docker-server "$REGISTRY_URL" \
      --docker-password "$IBMCLOUD_API_KEY" \
      --docker-username iamapikey \
      --docker-email ibm@example.com \
      "$IMAGE_PULL_SECRET_NAME"
  fi
fi

if kubectl get serviceaccount -o json default --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" | jq -e 'has("imagePullSecrets")'; then
  if kubectl get serviceaccount -o json default --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" | jq --arg name "$IMAGE_PULL_SECRET_NAME" -e '.imagePullSecrets[] | select(.name == $name)'; then
    echo "Image pull secret $IMAGE_PULL_SECRET_NAME found in $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
  else
    echo "Adding image pull secret $IMAGE_PULL_SECRET_NAME to $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
    kubectl patch serviceaccount \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --type json \
      --patch '[{"op": "add", "path": "/imagePullSecrets/-", "value": {"name": "'"$IMAGE_PULL_SECRET_NAME"'"}}]' \
      default
  fi
else
  echo "Adding image pull secret $IMAGE_PULL_SECRET_NAME to $IBMCLOUD_IKS_CLUSTER_NAMESPACE"
  kubectl patch serviceaccount \
    --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
    --patch '{"imagePullSecrets":[{"name":"'"$IMAGE_PULL_SECRET_NAME"'"}]}' \
    default
fi

IMAGE_NAME="${REGISTRY_URL}"/"${REGISTRY_NAMESPACE}"/"${IMAGES_NAME_BACKEND}":"${REGISTRY_TAG}"
echo "IMAGE_NAME:"
echo ${IMAGE_NAME}

YAML_FILE="deployments/kubernetes.yml"
cp ${YAML_FILE} "${YAML_FILE}org"
rm ${YAML_FILE}
sed "s#IMAGE_NAME#${IMAGE_NAME}#g" "${YAML_FILE}org" > ${YAML_FILE}
cat ${YAML_FILE}

deployment_name=$(yq r ${YAML_FILE} metadata.name)
service_name=$(yq r -d1 ${YAML_FILE} metadata.name)
echo "deployment_name:"
echo ${deployment_name}
echo "service_name:"
echo ${service_name}


#####################

ibmcloud resource service-key ${POSTGRES_SERVICE_KEY_NAME} --output JSON > ./postgres-key-temp.json  
POSTGRES_CERTIFICATE_CONTENT_ENCODED=$(cat ./postgres-key-temp.json | jq '.[].credentials.connection.cli.certificate.certificate_base64' | sed 's/"//g' ) 
POSTGRES_USERNAME=$(cat ./postgres-key-temp.json | jq '.[].credentials.connection.postgres.authentication.username' | sed 's/"//g' )
POSTGRES_PASSWORD=$(cat ./postgres-key-temp.json | jq '.[].credentials.connection.postgres.authentication.password' | sed 's/"//g' )
POSTGRES_HOST=$(cat ./postgres-key-temp.json | jq '.[].credentials.connection.postgres.hosts[].hostname' | sed 's/"//g' )
POSTGRES_PORT=$(cat ./postgres-key-temp.json | jq '.[].credentials.connection.postgres.hosts[].port' | sed 's/"//g' )
POSTGRES_CERTIFICATE_DATA=$(echo "$POSTGRES_CERTIFICATE_CONTENT_ENCODED" | base64 -d)

POSTGRES_CONNECTION_TYPE='jdbc:postgresql://'
POSTGRES_CERTIFICATE_PATH='/cloud-postgres-cert'
POSTGRES_DATABASE_NAME="ibmclouddb"
POSTGRES_URL="$POSTGRES_CONNECTION_TYPE$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DATABASE_NAME?sslmode=verify-full&sslrootcert=$POSTGRES_CERTIFICATE_PATH"

#####################

ibmcloud resource service-key ${APPID_SERVICE_KEY_NAME} --output JSON > ./appid-key-temp.json
APPID_OAUTHSERVERURL=$(cat ./appid-key-temp.json | jq '.[].credentials.oauthServerUrl' | sed 's/"//g' ) 
APPID_CLIENT_ID=$(cat ./appid-key-temp.json | jq '.[].credentials.clientId' | sed 's/"//g' )

#####################

kubectl create secret generic postgres.certificate-data \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "POSTGRES_CERTIFICATE_DATA=$POSTGRES_CERTIFICATE_DATA"
kubectl create secret generic postgres.username \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "POSTGRES_USERNAME=$POSTGRES_USERNAME"
kubectl create secret generic postgres.password \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
kubectl create secret generic postgres.url \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "POSTGRES_URL=$POSTGRES_URL"

kubectl create secret generic appid.oauthserverurl \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "APPID_AUTH_SERVER_URL=$APPID_OAUTHSERVERURL"
kubectl create secret generic appid.client-id-catalog-service \
      --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" \
      --from-literal "APPID_CLIENT_ID=$APPID_CLIENT_ID"

#####################

kubectl apply --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" -f ${YAML_FILE}
if kubectl rollout status --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "deployment/$deployment_name"; then
  status=success
else
  status=failure
fi

kubectl get events --sort-by=.metadata.creationTimestamp -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE"

if [ "$status" = failure ]; then
  echo "Deployment failed"
  if [[ -z "$BREAK_GLASS" ]]; then
    ibmcloud cr quota
  fi
  exit 1
fi

IP_ADDRESS=$(kubectl get nodes -o json | jq -r '[.items[] | .status.addresses[] | select(.type == "ExternalIP") | .address] | .[0]')
PORT=$(kubectl get service -n  "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$service_name" -o json | jq -r '.spec.ports[0].nodePort')

echo "Application REST URL: http://${IP_ADDRESS}:${PORT}/category/2/products"

echo -n "http://${IP_ADDRESS}:${PORT}" > ../app-url
