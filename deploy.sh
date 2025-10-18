#!/bin/bash
set -e

# Creating variables:
#  - PROJECT_ID
#  - SERVICE_ACCOUNT_NAME
#  - IAM_ROLES
#  - GCP_SERVICES
source config.sh

# Parse arguments
for arg in "$@"; do
  case $arg in
    --hostId=*)
      HOST_ID="${arg#*=}"
      ;;
    --location=*)
      LOCATION="${arg#*=}"
      ;;
    --hostShortId=*)
      HOST_SHORT_ID="${arg#*=}"
      ;;
    *)
      echo "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

# Check if all required arguments are set
if [[ -z "$HOST_ID" || -z "$LOCATION" || -z "$HOST_SHORT_ID" ]]; then
  echo "Missing required arguments."
  echo "Usage: $0 --hostId=@default/my-first-host --location=europe-west1 --hostShortId=1ac9d8"
  exit 1
fi

# other parameters
ORGANIZATION=$(echo "$HOST_ID" | cut -d'@' -f2 | cut -d'/' -f1)
HOST_NAME=$(echo "$HOST_ID" | cut -d'/' -f2)
CURRENT_TIMESTAMP=$(($(date +%s)*1000 + $(date +%N | cut -b1-3)))

# set the current project to use by the gcloud command
gcloud config set project $PROJECT_ID

# Check if the account already exists
SERVICE_ACCOUNT=$(gcloud iam service-accounts list \
    --project="$PROJECT_ID" \
    --filter="displayName:$SERVICE_ACCOUNT_NAME" \
    --format="value(email)")

if [ -n "$SERVICE_ACCOUNT" ]; then
    echo "Service Account already exists: $SERVICE_ACCOUNT"
else
    echo "Creating Service Account: $SERVICE_ACCOUNT_NAME"
    
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
        --display-name="$SERVICE_ACCOUNT_NAME" \
        --project="$PROJECT_ID"

    # Get the account email
    SERVICE_ACCOUNT=$(gcloud iam service-accounts list \
        --project="$PROJECT_ID" \
        --filter="displayName:$SERVICE_ACCOUNT_NAME" \
        --format="value(email)")

    echo "Service Account created: $SERVICE_ACCOUNT"
fi

for ROLE in "${IAM_ROLES[@]}"; do
echo "Checking if $SERVICE_ACCOUNT already has $ROLE..."

EXISTING_BINDING=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.role:$ROLE AND bindings.members:serviceAccount:$SERVICE_ACCOUNT" \
    --format="value(bindings.role)")

if [ "$EXISTING_BINDING" == "$ROLE" ]; then
    echo "$SERVICE_ACCOUNT already has $ROLE. Skipping."
else
    echo "Granting $ROLE to $SERVICE_ACCOUNT..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SERVICE_ACCOUNT" \
        --role="$ROLE"
    echo "Done."
fi
done

# Create the Firestore database used to store hosts information (idempotent)
HOSTS_DATABASE_NAME="hosts"

if gcloud firestore databases describe --database="${HOSTS_DATABASE_NAME}" --format=none; then
    echo "Using existing database: ${HOSTS_DATABASE_NAME}"
else
    echo "Creating new database..."
    gcloud firestore databases create --database="${HOSTS_DATABASE_NAME}" --location="${LOCATION}" --format=none
    echo "Database created: ${HOSTS_DATABASE_NAME}"
fi

# Check we have 0 or 1 document that matches the hostId. Then check the hostShortId matches.
FIRESTORE_RUNQUERY_URL="https://firestore.googleapis.com/v1/projects/$PROJECT_ID/databases/$HOSTS_DATABASE_NAME/documents:runQuery"

# Build the Firestore structured query to filter documents by hostShortId = "toto"
QUERY_JSON=$(cat <<EOF
{
  "structuredQuery": {
    "from": [{"collectionId": "hosts"}],
    "where": {
      "fieldFilter": {
        "field": {"fieldPath": "hostId"},
        "op": "EQUAL",
        "value": {"stringValue": "$HOST_ID"}
      }
    }
  }
}
EOF
)

# Get the access token for authorization
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Send the query to Firestore and capture the raw JSON response
RESPONSE=$(curl -s -X POST "$FIRESTORE_RUNQUERY_URL" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$QUERY_JSON")

# Remove all newlines, tabs, and spaces to normalize the JSON format
COMPACT=$(echo "$RESPONSE" | tr -d '\n\r\t ')

# Count the number of matched documents by detecting the "document":{"name": pattern
COUNT=$(echo "$COMPACT" | grep -o '"document":{"name":' | wc -l | xargs)


# Case: more than 1 match → error
if [ "$COUNT" -gt 1 ]; then
    echo "Error: expected at most 1 document, but found $COUNT."
    exit 1
fi

# Case: exactly 1 match → check if hostShortId matches
if [ "$COUNT" -eq 1 ]; then
    MATCHED_VALUE=$(echo "$RESPONSE" | grep '"hostShortId"' -A 2 | grep '"stringValue"' | sed -E 's/.*"stringValue"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n 1)

    if [ "$MATCHED_VALUE" != "$HOST_SHORT_ID" ]; then
        echo "Error: hostShortId in Firestore is '$MATCHED_VALUE', not '$HOST_SHORT_ID'."
        exit 1
    fi
fi

# Firestore document URL for this hostShortId
FIRESTORE_URL="https://firestore.googleapis.com/v1/projects/$PROJECT_ID/databases/$HOSTS_DATABASE_NAME/documents/hosts/$HOST_SHORT_ID"

# Get access token and fetch the document
HTTP_CODE_GET=$(curl -s -w "%{http_code}" -o response.json -H "Authorization: Bearer $ACCESS_TOKEN" "$FIRESTORE_URL")
DOCUMENT=$(cat response.json)

if [ "$HTTP_CODE_GET" -eq 200 ] || [ "$HTTP_CODE_GET" -eq 201 ]; then
    EXISTING_HOST_ID=$(echo "$DOCUMENT" \
        | grep -A 2 '"hostId"' \
        | grep '"stringValue"' \
        | sed -E 's/.*"stringValue"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
        | head -n 1)

    if [ "$EXISTING_HOST_ID" != "$HOST_ID" ]; then
        echo "Error: hostShortId '$HOST_SHORT_ID' is already used by another hostId ('$EXISTING_HOST_ID')."
        exit 1
    fi
fi

# Build JSON body to update or create the document
JSON_BODY=$(cat <<EOF
{
  "fields": {
    "hostId":        { "stringValue": "$HOST_ID" },
    "hostShortId":   { "stringValue": "$HOST_SHORT_ID" },
    "updatedAt":     { "doubleValue": "$CURRENT_TIMESTAMP" }
  }
}
EOF
)

# Send PATCH request (create or update)
HTTP_CODE_PATCH=$(curl -s -w "%{http_code}" -o response.json -X PATCH "$FIRESTORE_URL" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$JSON_BODY")

# Check update result
if [ "$HTTP_CODE_PATCH" -eq 200 ] || [ "$HTTP_CODE_PATCH" -eq 201 ]; then
    echo "The host information was successfully updated."
else
    echo "Error: failed to update host information. HTTP code: $HTTP_CODE_PATCH"
    exit 1
fi

# enable needed gcp services
echo "Enabling services..."
gcloud services enable "${GCP_SERVICES[@]}"
echo "Services enabled."


# Create the Firestore database (idempotent)
AGENT_DATABASE_NAME="agent-db-${HOST_SHORT_ID}"

if gcloud firestore databases describe --database="${AGENT_DATABASE_NAME}" --format=none; then
    echo "Using existing database: ${AGENT_DATABASE_NAME}"
else
    echo "Creating new database..."
    gcloud firestore databases create \
        --database="${AGENT_DATABASE_NAME}" \
        --location="${LOCATION}" \
        --format=none
    echo "Database created: ${AGENT_DATABASE_NAME}"
fi

# Check if the required index exists (basic check by listing existing ones)
INDEX_EXISTS=$(gcloud firestore indexes composite list \
    --database="${AGENT_DATABASE_NAME}" \
    --filter="COLLECTION_GROUP:deployments" \
    --format="value(state)")

if [[ -n "$INDEX_EXISTS" ]]; then
    echo "Index already exists for collection 'deployments'"
else
    echo "Creating new indexes for collection 'deployments'..."
    gcloud firestore indexes composite create \
        --database="${AGENT_DATABASE_NAME}" \
        --collection-group=deployments \
        --field-config=field-path=state,order=ascending \
        --field-config=field-path=createdAt,order=ascending

    gcloud firestore indexes composite create \
        --database="${AGENT_DATABASE_NAME}" \
        --collection-group=deployments \
        --field-config=field-path=state,order=ascending \
        --field-config=field-path=createdAt,order=descending

    echo "Indexes created for collection 'deployments'."
fi

# Create Artifact Registry repositories

JOBS_REPOSITORY_NAME="jobs-${HOST_SHORT_ID}"

if gcloud artifacts repositories describe "${JOBS_REPOSITORY_NAME}" --location="${LOCATION}" --format=none; then
    echo "Using existing ${JOBS_REPOSITORY_NAME} repository."
else
    echo "Creating new repository..."
    gcloud artifacts repositories create "${JOBS_REPOSITORY_NAME}" \
        --repository-format=docker \
        --location="${LOCATION}" \
        --description="Jobs for host ${HOST_ID}"
    echo "Repository created: ${JOBS_REPOSITORY_NAME}"
fi

NODEJS_PACKAGES_REPOSITORY_NAME="nodejs-packages-${HOST_SHORT_ID}"

if gcloud artifacts repositories describe "${NODEJS_PACKAGES_REPOSITORY_NAME}" --location="${LOCATION}" --format=none; then
    echo "Using existing ${NODEJS_PACKAGES_REPOSITORY_NAME} repository."
else
    echo "Creating new repository..."
    gcloud artifacts repositories create "${NODEJS_PACKAGES_REPOSITORY_NAME}" \
        --repository-format=npm \
        --location="${LOCATION}" \
        --description="nodejs packages for host ${HOST_ID}"
    echo "Repository created: ${NODEJS_PACKAGES_REPOSITORY_NAME}"
fi

# Create Metric Job
# TODO MANAGE TIMEZONE - should be asked at host creation !!
METRICS_JOB_NAME="metrics-job-${HOST_SHORT_ID}"
METRICS_IMAGE_NAME="metrics-image-${HOST_SHORT_ID}"
METRICS_IMAGE_URI=$LOCATION-docker.pkg.dev/$PROJECT_ID/$JOBS_REPOSITORY_NAME/$METRICS_IMAGE_NAME
METRICS_SCHEDULER_NAME="scheduler-${HOST_SHORT_ID}"
METRICS_JOB_EXECUTE_URL="https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${LOCATION}/jobs/${METRICS_JOB_NAME}:run"

gcloud builds submit ./jobs/metrics --tag $METRICS_IMAGE_URI 

gcloud run jobs deploy $METRICS_JOB_NAME \
    --image $METRICS_IMAGE_URI \
    --region $LOCATION \
    --command="/bin/bash" \
    --args=-c,"node job.js" \
    --service-account $SERVICE_ACCOUNT \
    --set-env-vars="AGENT_DATABASE_NAME=${AGENT_DATABASE_NAME}"

if gcloud scheduler jobs describe "$METRICS_SCHEDULER_NAME" --location="$LOCATION" --project="$PROJECT_ID" --format=none; then
    echo "Job '$METRICS_SCHEDULER_NAME' already exists. Updating."
    gcloud scheduler jobs update http "$METRICS_SCHEDULER_NAME" \
        --schedule="5 * * * *" \
        --http-method=POST \
        --uri="$METRICS_JOB_EXECUTE_URL" \
        --oauth-service-account-email="$SERVICE_ACCOUNT" \
        --location="$LOCATION" \
        --project="$PROJECT_ID"
else
    echo "Creating job '$METRICS_SCHEDULER_NAME'..."
    gcloud scheduler jobs create http "$METRICS_SCHEDULER_NAME" \
        --schedule="5 * * * *" \
        --http-method=POST \
        --uri="$METRICS_JOB_EXECUTE_URL" \
        --oauth-service-account-email="$SERVICE_ACCOUNT" \
        --location="$LOCATION" \
        --project="$PROJECT_ID"
fi

# --schedule="*/2 * * * *" \
# --schedule="5 * * * *" \
# --time-zone="Europe/Paris" \

# Create the buckets

# Create a bucket with the name (with increment) provided. If already exists return the existing one.
# If already exist in another account add an increment to find a free name.
create_bucket () {
    NAME=$1
    INCREMENT=0
    BUCKET=""
    while [ -z "$BUCKET" ];
    do
        BUCKET_NAME="${NAME}-${HOST_SHORT_ID}-${INCREMENT}"
        BUCKET=$(gcloud storage buckets list --filter="name=${BUCKET_NAME}" --format="value(name)")
        if [ -z "$BUCKET" ]; then
            gcloud storage buckets create "gs://${BUCKET_NAME}" --no-user-output-enabled || true
            BUCKET=$(gcloud storage buckets list --filter="name=${BUCKET_NAME}" --format="value(name)")
        fi
        INCREMENT=$((INCREMENT+1))
    done
    echo $BUCKET
}

PLANS_BUCKET=$(create_bucket plans)
echo "Using agent bucket: ${PLANS_BUCKET}"

SERVICES_ARCHIVE_BUCKET=$(create_bucket services-archive)
echo "Using services-archive bucket: ${SERVICES_ARCHIVE_BUCKET}"
SERVICES_FILES_BUCKET=$(create_bucket services-files)
echo "Using services-files bucket: ${SERVICES_FILES_BUCKET}"

RESOURCES_ARCHIVE_BUCKET=$(create_bucket resources-archive)
echo "Using resources-archive bucket: ${RESOURCES_ARCHIVE_BUCKET}"

AGENT_DEPLOY_APP_WORKFLOW_NAME="agent-deploy-app-workflow-${HOST_SHORT_ID}"
AGENT_DEPLOY_APP_WORKFLOW=projects/$PROJECT_ID/locations/$LOCATION/workflows/$AGENT_DEPLOY_APP_WORKFLOW_NAME

# Deploy the agent-backend
gcloud functions deploy "agent-backend-${HOST_SHORT_ID}" \
    --gen2 \
    --region="europe-west1" \
    --runtime="nodejs20" \
    --entry-point="handle" \
    --source="./functions/agent-backend/" \
    --trigger-http \
    --no-allow-unauthenticated \
    --service-account="${SERVICE_ACCOUNT}" \
    --update-labels="backend-id=4234" \
    --set-env-vars="PROJECT_ID=${PROJECT_ID}" \
    --set-env-vars="SERVICE_ACCOUNT=${SERVICE_ACCOUNT}" \
    --set-env-vars="LOCATION=${LOCATION}" \
    --set-env-vars="HOST_ID=${HOST_ID}" \
    --set-env-vars="HOST_SHORT_ID=${HOST_SHORT_ID}" \
    --set-env-vars="AGENT_DATABASE_NAME=${AGENT_DATABASE_NAME}" \
    --set-env-vars="AGENT_DEPLOY_APP_WORKFLOW=${AGENT_DEPLOY_APP_WORKFLOW}" \
    --set-env-vars="PLANS_BUCKET=${PLANS_BUCKET}" \
    --set-env-vars="SERVICES_ARCHIVE_BUCKET=${SERVICES_ARCHIVE_BUCKET}" \
    --set-env-vars="RESOURCES_ARCHIVE_BUCKET=${RESOURCES_ARCHIVE_BUCKET}"

AGENT_HOST_URL=$(gcloud functions describe "agent-backend-${HOST_SHORT_ID}" --region=europe-west1 --gen2 --format="value(serviceConfig.uri)")
AGENT_HOST_URL_SED=$(echo "$AGENT_HOST_URL" | sed 's/\//\\\//g')

# Deploy the workflows
sed "s/{{PROJECT_ID}}/$PROJECT_ID/g;s/{{LOCATION}}/$LOCATION/g;s/{{ORGANIZATION}}/$ORGANIZATION/g;s/{{HOST_NAME}}/$HOST_NAME/g;s/{{HOST_SHORT_ID}}/$HOST_SHORT_ID/g;s/{{HOST_URL}}/$AGENT_HOST_URL_SED/g;s/{{SERVICES_ARCHIVE_BUCKET}}/$SERVICES_ARCHIVE_BUCKET/g;s/{{SERVICES_FILES_BUCKET}}/$SERVICES_FILES_BUCKET/g;s/{{RESOURCES_ARCHIVE_BUCKET}}/$RESOURCES_ARCHIVE_BUCKET/g" ./workflows/AgentDeployAppWorkflow.yaml > AgentDeployAppWorkflow.yaml

gcloud workflows deploy $AGENT_DEPLOY_APP_WORKFLOW_NAME \
    --source=./AgentDeployAppWorkflow.yaml \
    --location=europe-west1 \
    --service-account="$SERVICE_ACCOUNT" \
    --format=none

rm ./AgentDeployAppWorkflow.yaml


# Deploy the API Gateway
sed -e "s/\${organization}/${ORGANIZATION}/" -e "s/\${hostName}/${HOST_NAME}/" -e "s/\${hostUrl}/${AGENT_HOST_URL_SED}/" ./apigw/openapi.yaml > openapi.yaml

OPENAPI_HASH=$(md5 -q openapi.yaml)
AGENT_API_NAME="api-${HOST_SHORT_ID}"
AGENT_API_GW_NAME="api-gw-${HOST_SHORT_ID}"
AGENT_API_CFG_NAME="api-cfg-${HOST_SHORT_ID}-${OPENAPI_HASH}"

if (gcloud api-gateway apis describe $AGENT_API_NAME --format=none); then
    echo "Using existing API: ${AGENT_API_NAME}"
else
    gcloud api-gateway apis create $AGENT_API_NAME
fi

if (gcloud api-gateway api-configs describe $AGENT_API_CFG_NAME --api=$AGENT_API_NAME --format=none); then
    echo "Using existing API Config: ${AGENT_API_CFG_NAME}"
else
    gcloud api-gateway api-configs create $AGENT_API_CFG_NAME --api=$AGENT_API_NAME --openapi-spec=./openapi.yaml
fi
rm ./openapi.yaml

AGENT_API_CFG_ID=$(gcloud api-gateway api-configs describe $AGENT_API_CFG_NAME --api=$AGENT_API_NAME --format="value(name)")

if (gcloud api-gateway gateways describe $AGENT_API_GW_NAME --location=europe-west1 --format=none); then
    AGENT_API_GW_CFG_ID=$(gcloud api-gateway gateways describe $AGENT_API_GW_NAME --location=europe-west1 --format="value(apiConfig)")
else
    AGENT_API_GW_CFG_ID=""
fi

if [ "$AGENT_API_GW_CFG_ID" = "" ]; then
    gcloud api-gateway gateways create $AGENT_API_GW_NAME --api=$AGENT_API_NAME --api-config=$AGENT_API_CFG_NAME --location=europe-west1 --project=${PROJECT_ID}
elif [ "$AGENT_API_GW_CFG_ID" = "$AGENT_API_CFG_ID" ]; then
    echo "Using existing API Gateway: ${AGENT_API_GW_NAME}"
else
    gcloud api-gateway gateways update $AGENT_API_GW_NAME --api=$AGENT_API_NAME --api-config=$AGENT_API_CFG_NAME --location=europe-west1
fi

HOST_URL=$(gcloud api-gateway gateways describe $AGENT_API_GW_NAME --location=europe-west1 --format="value(defaultHostname)")

echo "Host URL: https://${HOST_URL}"