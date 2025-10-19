#!/bin/bash
set -e

# **********************************************************
# COMMAND LINE PARAMETERS
# **********************************************************
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

ORGANIZATION=$(echo "$HOST_ID" | cut -d'@' -f2 | cut -d'/' -f1)
HOST_NAME=$(echo "$HOST_ID" | cut -d'/' -f2)

# **********************************************************
# CONFIGURATION
# **********************************************************

# GCP project ID
PROJECT_ID=$(gcloud config get-value project)

# Current timestamp in ms
CURRENT_TIMESTAMP=$(date +%s%3N)

# Roles to use by the agent
# TODO: the agent needs the setIamPolicy role on resource we deploy (Cloud Run for instance).
# We use the owner role for that, not a good practice, maybe we can use mode specific roles
IAM_ROLES=(
    roles/owner
)

# GCP service to activate on the GCP Project
GCP_SERVICES=(
    monitoring.googleapis.com
    cloudscheduler.googleapis.com
    logging.googleapis.com
    cloudbuild.googleapis.com
    compute.googleapis.com
    apigateway.googleapis.com
    servicecontrol.googleapis.com
    eventarc.googleapis.com
    eventarcpublishing.googleapis.com
    appengine.googleapis.com
    firestore.googleapis.com
    iam.googleapis.com
    cloudfunctions.googleapis.com
    workflows.googleapis.com
    cloudresourcemanager.googleapis.com
    run.googleapis.com
    artifactregistry.googleapis.com
)

# Service account name
SERVICE_ACCOUNT_NAME="blueforge"

AGENT_DATABASE_NAME="agent-db-${HOST_SHORT_ID}"

JOBS_REPOSITORY_NAME="jobs-${HOST_SHORT_ID}"
NODEJS_PACKAGES_REPOSITORY_NAME="nodejs-packages-${HOST_SHORT_ID}"

METRICS_JOB_IMAGE="!!!!!!!!!!!!!!!!!" # TODO
METRICS_JOB_NAME="metrics-job-${HOST_SHORT_ID}"
METRICS_SCHEDULER_NAME="scheduler-${HOST_SHORT_ID}"
METRICS_JOB_EXECUTE_URL="https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${LOCATION}/jobs/${METRICS_JOB_NAME}:run"

AGENT_RUN_SERVICE_NAME="agent-${HOST_SHORT_ID}"
GCP_AGENT_IMAGE="!!!!!!!!!!!!!!!!!" # TODO
WORKFLOW_HELPER_RUN_SERVICE_NAME="workflow-helper-${HOST_SHORT_ID}"
GCP_WORKFLOW_HELPER_IMAGE="!!!!!!!!!!!!!!!!!" # TODO

AGENT_DEPLOY_APP_WORKFLOW_NAME="agent-deploy-app-workflow-${HOST_SHORT_ID}"
AGENT_DEPLOY_APP_WORKFLOW=projects/$PROJECT_ID/locations/$LOCATION/workflows/$AGENT_DEPLOY_APP_WORKFLOW_NAME

# **********************************************************
# RUN SCRIPT - IDEMPOTENT
# **********************************************************

# ----------------------------------------------------------
# Enable services
# ----------------------------------------------------------
echo "Enabling services..."
gcloud services enable "${GCP_SERVICES[@]}"
echo "Services enabled."

# ----------------------------------------------------------
# Service Account + Roles
# ----------------------------------------------------------
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

# ----------------------------------------------------------
# Buckets
# ----------------------------------------------------------
# Helper to create a bucket with the name (with increment) provided. If already exists return the existing one.
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

# ----------------------------------------------------------
# Database
# ----------------------------------------------------------
# Create the Firestore database (idempotent)
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

# ----------------------------------------------------------
# Artifact Registry Repositories - A QUOI IL SERT DEJA ? :D
# ----------------------------------------------------------
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

# ----------------------------------------------------------
# Cloud run jobs: Metrics
# ----------------------------------------------------------
gcloud run jobs deploy $METRICS_JOB_NAME \
    --image $METRICS_JOB_IMAGE \
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

# ----------------------------------------------------------
# Cloud run services: Workflow Helper, Agent
# ----------------------------------------------------------
# Deploy the workflow helper run service
gcloud run deploy $WORKFLOW_HELPER_RUN_SERVICE_NAME \
    --image $GCP_WORKFLOW_HELPER_IMAGE \
    --region $LOCATION \
    --runtime="nodejs20" \
    --no-allow-unauthenticated \
    --service-account="${SERVICE_ACCOUNT}" \
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

# Deploy the agent cloud run service
gcloud run deploy $AGENT_RUN_SERVICE_NAME \
    --image $GCP_AGENT_IMAGE \
    --region $LOCATION \
    --runtime="nodejs20" \
    --allow-unauthenticated \
    --service-account="${SERVICE_ACCOUNT}" \
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

WORKFLOW_HELPER_HOST_URL=$(gcloud run services describe $WORKFLOW_HELPER_RUN_SERVICE_NAME --region="${LOCATION}" --format="value(url)")
WORKFLOW_HELPER_HOST_URL_SED=$(echo "$WORKFLOW_HELPER_HOST_URL" | sed 's/\//\\\//g')

AGENT_HOST_URL=$(gcloud run services describe $AGENT_RUN_SERVICE_NAME --region="${LOCATION}" --format="value(url)")
AGENT_HOST_URL_SED=$(echo "$AGENT_HOST_URL" | sed 's/\//\\\//g')

# ----------------------------------------------------------
# Workflows
# ----------------------------------------------------------
sed \
    -e "s/{{PROJECT_ID}}/$PROJECT_ID/g" \
    -e "s/{{LOCATION}}/$LOCATION/g" \
    -e "s/{{ORGANIZATION}}/$ORGANIZATION/g" \
    -e "s/{{HOST_NAME}}/$HOST_NAME/g" \
    -e "s/{{HOST_SHORT_ID}}/$HOST_SHORT_ID/g" \
    -e "s/{{HOST_URL}}/$AGENT_HOST_URL_SED/g" \
    -e "s/{{SERVICES_ARCHIVE_BUCKET}}/$SERVICES_ARCHIVE_BUCKET/g" \
    -e "s/{{SERVICES_FILES_BUCKET}}/$SERVICES_FILES_BUCKET/g" \
    -e "s/{{RESOURCES_ARCHIVE_BUCKET}}/$RESOURCES_ARCHIVE_BUCKET/g" \
    ./workflows/AgentDeployAppWorkflow.yaml > AgentDeployAppWorkflow.yaml

gcloud workflows deploy $AGENT_DEPLOY_APP_WORKFLOW_NAME \
    --source=./AgentDeployAppWorkflow.yaml \
    --location=europe-west1 \
    --service-account="$SERVICE_ACCOUNT" \
    --format=none

rm ./AgentDeployAppWorkflow.yaml

if [[ -n "${BUILDER_OUTPUT:-}" ]]; then
  mkdir -p "${BUILDER_OUTPUT}"
  printf '%s\n' "{\"AGENT_HOST_URL\":\"${AGENT_HOST_URL}\"}" > "${BUILDER_OUTPUT}/output"
fi

echo "Host URL: https://${AGENT_HOST_URL}"
