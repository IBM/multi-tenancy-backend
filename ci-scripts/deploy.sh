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
APPID_MANAGEMENT_URL=$(cat ./appid-key-temp.json | jq '.[].credentials.managementUrl' | sed 's/"//g' )

OAUTHTOKEN=$(ibmcloud iam oauth-tokens | awk '{print $4;}')
echo $OAUTHTOKEN
APPID_MANAGEMENT_URL_ALL_APPLICATIONS=${APPID_MANAGEMENT_URL}/applications
echo $APPID_MANAGEMENT_URL_ALL_APPLICATIONS
result=$(curl -H "Content-Type: application/json" -H "Authorization: Bearer $OAUTHTOKEN" $APPID_MANAGEMENT_URL_ALL_APPLICATIONS)
echo $result
APPID_CLIENT_ID=$(echo $result | sed -n 's|.*"clientId":"\([^"]*\)".*|\1|p')
echo $APPID_CLIENT_ID

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


PLATFORM_NAME="$(get_env PLATFORM_NAME)"
#if [ "$PLATFORM_NAME" = "IBM_KUBERNETES_SERVICE" ]; then
#    //HOST=$(ibmcloud ks cluster get --c $(get_env IBM_KUBERNETES_SERVICE_NAME) --output json | jq -r '[.ingressHostname] | .[0]')
#    HOST="service-backend.cluster-ingress-subdomain"
#else
    #TODO rework HOST this with jq
#    HOST=$(ibmcloud oc cluster get -c $(get_env IBM_OPENSHIFT_SERVICE_NAME) --output json | grep "hostname" | awk '{print $2;}'| sed 's/"//g' | sed 's/,//g')
    #With OpenShift, TLS secret for default Ingress subdomain only exists in project openshift-ingress, so need to extract and re-create in tenant project
#    TLS_SECRET_NAME=$(echo $HOST| cut -d'.' -f 1)
#    echo "Openshift TLS_SECRET_NAME=$TLS_SECRET_NAME"
#    oc extract secret/"$TLS_SECRET_NAME" --to=. -n openshift-ingress
#    oc create secret tls cluster-ingress-secret -n "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" --cert tls.crt --key tls.key
#    rm tls.crt tls.key
#fi

#Update the kubernetes deployment descriptor
#HOST_HTTP=${HOST}
#HOST_TLS=${HOST}
#rm "${YAML_FILE}org"
#cp ${YAML_FILE} "${YAML_FILE}org"
#rm ${YAML_FILE}
#sed "s#HOST_HTTP#${HOST_HTTP}#g" "${YAML_FILE}org" > ${YAML_FILE}
#rm "${YAML_FILE}org"
#cp ${YAML_FILE} "${YAML_FILE}org"
#rm ${YAML_FILE}
#sed "s#HOST_TLS#${HOST_TLS}#g" "${YAML_FILE}org" > ${YAML_FILE}
#cat ${YAML_FILE}


# Create Ingress and prepare Ingress subdomain TLS secret
CLUSTER_INGRESS_SUBDOMAIN=$( ibmcloud ks cluster get --cluster ${IBMCLOUD_IKS_CLUSTER_NAME} --json | jq -r '.ingressHostname // .ingress.hostname' | cut -d, -f1 )
CLUSTER_INGRESS_SECRET=$( ibmcloud ks cluster get --cluster ${IBMCLOUD_IKS_CLUSTER_NAME} --json | jq -r '.ingressSecretName // .ingress.secretName' | cut -d, -f1 )
if [ ! -z "${CLUSTER_INGRESS_SUBDOMAIN}" ] && [ "${KEEP_INGRESS_CUSTOM_DOMAIN}" != true ]; then
  echo "=========================================================="
  echo "UPDATING manifest with ingress information"
  INGRESS_DOC_INDEX=$(yq read --doc "*" --tojson ${YAML_FILE} | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="ingress") | .key')
  if [ -z "$INGRESS_DOC_INDEX" ]; then
    echo "No Kubernetes Ingress definition found in ${YAML_FILE}."
  else
    # Update ingress with cluster domain/secret information
    # Look for ingress rule whith host contains the token "cluster-ingress-subdomain"
    INGRESS_RULES_INDEX=$(yq r --doc $INGRESS_DOC_INDEX --tojson ${YAML_FILE} | jq '.spec.rules | to_entries | .[] | select( .value.host | contains("cluster-ingress-subdomain")) | .key')
    if [ ! -z "$INGRESS_RULES_INDEX" ]; then
      INGRESS_RULE_HOST=$(yq r --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.rules[${INGRESS_RULES_INDEX}].host)
      HOST_APP_NAME="$(cut -d'.' -f1 <<<"$INGRESS_RULE_HOST")"
      HOST_APP_NAME_DEPLOYMENT=${HOST_APP_NAME}-${IBMCLOUD_IKS_CLUSTER_NAMESPACE}-deployment
      yq w --inplace --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.rules[${INGRESS_RULES_INDEX}].host ${INGRESS_RULE_HOST/$HOST_APP_NAME/$HOST_APP_NAME_DEPLOYMENT}
      INGRESS_RULE_HOST=$(yq r --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.rules[${INGRESS_RULES_INDEX}].host)
      yq w --inplace --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.rules[${INGRESS_RULES_INDEX}].host ${INGRESS_RULE_HOST/cluster-ingress-subdomain/$CLUSTER_INGRESS_SUBDOMAIN}
    fi
    # Look for ingress tls whith secret contains the token "cluster-ingress-secret"
    INGRESS_TLS_INDEX=$(yq r --doc $INGRESS_DOC_INDEX --tojson ${YAML_FILE} | jq '.spec.tls | to_entries | .[] | select(.secretName="cluster-ingress-secret") | .key')
    if [ ! -z "$INGRESS_TLS_INDEX" ]; then
      yq w --inplace --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.tls[${INGRESS_TLS_INDEX}].secretName $CLUSTER_INGRESS_SECRET
      INGRESS_TLS_HOST_INDEX=$(yq r --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.tls[${INGRESS_TLS_INDEX}] --tojson | jq '.hosts | to_entries | .[] | select( .value | contains("cluster-ingress-subdomain")) | .key')
      if [ ! -z "$INGRESS_TLS_HOST_INDEX" ]; then
        INGRESS_TLS_HOST=$(yq r --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.tls[${INGRESS_TLS_INDEX}].hosts[$INGRESS_TLS_HOST_INDEX])
        HOST_APP_NAME="$(cut -d'.' -f1 <<<"$INGRESS_TLS_HOST")"
        HOST_APP_NAME_DEPLOYMENT=${HOST_APP_NAME}-${IBMCLOUD_IKS_CLUSTER_NAMESPACE}-deployment
        yq w --inplace --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.tls[${INGRESS_TLS_INDEX}].hosts[$INGRESS_TLS_HOST_INDEX] ${INGRESS_TLS_HOST/$HOST_APP_NAME/$HOST_APP_NAME_DEPLOYMENT}
        INGRESS_TLS_HOST=$(yq r --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.tls[${INGRESS_TLS_INDEX}].hosts[$INGRESS_TLS_HOST_INDEX])
        yq w --inplace --doc $INGRESS_DOC_INDEX ${YAML_FILE} spec.tls[${INGRESS_TLS_INDEX}].hosts[$INGRESS_TLS_HOST_INDEX] ${INGRESS_TLS_HOST/cluster-ingress-subdomain/$CLUSTER_INGRESS_SUBDOMAIN}
      fi
    fi
    if kubectl explain route > /dev/null 2>&1; then 
      if kubectl get secret ${CLUSTER_INGRESS_SECRET} --namespace=openshift-ingress; then
        if kubectl get secret ${CLUSTER_INGRESS_SECRET} --namespace ${IBMCLOUD_IKS_CLUSTER_NAMESPACE}; then 
          echo "TLS Secret exists in the ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} namespace."
        else 
          echo "TLS Secret does not exists in the ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} namespace. Copying from openshift-ingress."
          kubectl get secret ${CLUSTER_INGRESS_SECRET} --namespace=openshift-ingress -oyaml | grep -v '^\s*namespace:\s' | kubectl apply --namespace=${IBMCLOUD_IKS_CLUSTER_NAMESPACE} -f -
        fi
      fi
    else
      if kubectl get secret ${CLUSTER_INGRESS_SECRET} --namespace=default; then
        if kubectl get secret ${CLUSTER_INGRESS_SECRET} --namespace ${IBMCLOUD_IKS_CLUSTER_NAMESPACE}; then 
          echo "TLS Secret exists in the ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} namespace."
        else 
          echo "TLS Secret does not exists in the ${IBMCLOUD_IKS_CLUSTER_NAMESPACE} namespace. Copying from default."
          kubectl get secret ${CLUSTER_INGRESS_SECRET} --namespace=default -oyaml | grep -v '^\s*namespace:\s' | kubectl apply --namespace=${IBMCLOUD_IKS_CLUSTER_NAMESPACE} -f -
        fi
      fi
    fi
  fi
fi




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


echo "CLUSTER_INGRESS_SUBDOMAIN=${CLUSTER_INGRESS_SUBDOMAIN}"
echo "KEEP_INGRESS_CUSTOM_DOMAIN=${KEEP_INGRESS_CUSTOM_DOMAIN}"

if [ ! -z "${CLUSTER_INGRESS_SUBDOMAIN}" ] && [ "${KEEP_INGRESS_CUSTOM_DOMAIN}" != true ]; then
  INGRESS_DOC_INDEX=$(yq read --doc "*" --tojson ${YAML_FILE} | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="ingress") | .key')
  if [ -z "$INGRESS_DOC_INDEX" ]; then
    echo "No Kubernetes Ingress definition found in ${YAML_FILE}."
  else
    service_name=$(yq r --doc $INGRESS_DOC_INDEX ${YAML_FILE} metadata.name)  
    APPURL=$(kubectl get ing ${service_name} --namespace "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" -o json | jq -r  .spec.rules[0].host)
    echo "Application Backend URL (via Ingress): https://${APPURL}/category/2/products"
    APP_URL_PATH="$(echo "${INVENTORY_ENTRY}" | sed 's/\//_/g')_app-url.json"
    echo -n https://${APPURL} > ../app-url
  fi

else 

  if [ "$PLATFORM_NAME" = "IBM_KUBERNETES_SERVICE" ]; then
    IP_ADDRESS=$(kubectl get nodes -o json | jq -r '[.items[] | .status.addresses[] | select(.type == "ExternalIP") | .address] | .[0]')
    PORT=$(kubectl get service -n  "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$service_name" -o json | jq -r '.spec.ports[0].nodePort')
    echo "IKS Application REST URL (via NodePort): http://${IP_ADDRESS}:${PORT}/category/2/products"
    echo -n "http://${IP_ADDRESS}:${PORT}" > ../app-url


  else
    
    IP_ADDRESS=$(kubectl get nodes -o json | jq -r '[.items[] | .status.addresses[] | select(.type == "ExternalIP") | .address] | .[0]')
    PORT=$(kubectl get service -n  "$IBMCLOUD_IKS_CLUSTER_NAMESPACE" "$service_name" -o json | jq -r '.spec.ports[0].nodePort')

    echo "OpenShift Application REST URL (via NodePort): http://${IP_ADDRESS}:${PORT}/category/2/products"
    echo "N.B This URL will not work unless you are connected to IBM Cloud via VPN, because OpenShift workers do not have a public IP"
    echo -n "http://${IP_ADDRESS}:${PORT}" > ../app-url


  fi

fi


