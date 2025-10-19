#!/bin/bash
set -e

# ==============================================================================
# GCP Infrastructure Setup Script for BlueForge Agent
# ==============================================================================
#
# This script provisions and configures all necessary GCP resources for a
# BlueForge agent environment. It is designed to be idempotent and can be
# safely re-run without causing duplicate resources or errors.
#
# USAGE:
#   ./setup.sh --hostId=@default/my-first-host \
#              --location=europe-west1 \
#              --hostShortId=1ac9d8
#
# REQUIRED ARGUMENTS:
#   --hostId        Fully qualified host identifier (format: @org/hostname)
#   --location      GCP region for resource deployment
#   --hostShortId   Short unique identifier for this host instance
#
# PREREQUISITES:
#   - gcloud CLI installed and authenticated
#   - Active GCP project set as default
#   - Appropriate IAM permissions to create resources
#
# RESOURCES CREATED:
#   - Service accounts with IAM role bindings
#   - Cloud Storage buckets for plans, archives, and files
#   - Firestore database with composite indexes
#   - Artifact Registry repositories
#   - Cloud Run services (agent and workflow helper)
#   - Cloud Run jobs with Cloud Scheduler triggers
#   - Workflows for application deployment
#
# ==============================================================================

# ==============================================================================
# COMMAND LINE ARGUMENT PARSING
# ==============================================================================

# Parse command line arguments using case pattern matching.
# Arguments are expected in --key=value format.
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

# Validate that all required arguments are provided.
if [[ -z "$HOST_ID" || -z "$LOCATION" || -z "$HOST_SHORT_ID" ]]; then
  echo "Missing required arguments."
  echo "Usage: $0 --hostId=@default/my-first-host --location=europe-west1 --hostShortId=1ac9d8"
  exit 1
fi

# Extract organization and host name from the fully qualified host ID.
# Expected format: @organization/hostname
ORGANIZATION=$(echo "$HOST_ID" | cut -d'@' -f2 | cut -d'/' -f1)
HOST_NAME=$(echo "$HOST_ID" | cut -d'/' -f2)

# ==============================================================================
# CONFIGURATION AND CONSTANTS
# ==============================================================================

# Retrieve the currently active GCP project ID from gcloud configuration.
PROJECT_ID=$(gcloud config get-value project)

# Generate current timestamp in milliseconds for versioning and tracking.
CURRENT_TIMESTAMP=$(date +%s%3N)

# Define IAM roles to be assigned to the service account.
# TODO: Replace 'roles/owner' with principle of least privilege roles.
# The agent requires setIamPolicy permissions on deployed resources (e.g., Cloud Run).
# Consider using more granular roles:
#   - roles/run.admin
#   - roles/iam.serviceAccountUser
#   - roles/storage.admin
#   - roles/firestore.admin
IAM_ROLES=(
    roles/owner
)

# List of GCP APIs required for this infrastructure.
# These services will be enabled if not already active.
GCP_SERVICES=(
    monitoring.googleapis.com          # Cloud Monitoring for metrics and logs
    cloudscheduler.googleapis.com      # Cloud Scheduler for cron jobs
    logging.googleapis.com             # Cloud Logging
    cloudbuild.googleapis.com          # Cloud Build for CI/CD
    compute.googleapis.com             # Compute Engine
    apigateway.googleapis.com          # API Gateway for routing
    servicecontrol.googleapis.com      # Service Control for API management
    eventarc.googleapis.com            # Eventarc for event-driven architectures
    eventarcpublishing.googleapis.com  # Eventarc publishing
    appengine.googleapis.com           # App Engine (required for some Firestore operations)
    firestore.googleapis.com           # Firestore native mode database
    iam.googleapis.com                 # Identity and Access Management
    cloudfunctions.googleapis.com      # Cloud Functions
    workflows.googleapis.com           # Cloud Workflows
    cloudresourcemanager.googleapis.com # Cloud Resource Manager
    run.googleapis.com                 # Cloud Run for containerized apps
    artifactregistry.googleapis.com    # Artifact Registry for container images
)

# Service account name for the BlueForge agent.
# This account will have permissions to manage resources.
SERVICE_ACCOUNT_NAME="blueforge"

# Firestore database name with host-specific suffix.
AGENT_DATABASE_NAME="agent-db-${HOST_SHORT_ID}"

# Artifact Registry repository names.
JOBS_REPOSITORY_NAME="jobs-${HOST_SHORT_ID}"
NODEJS_PACKAGES_REPOSITORY_NAME="nodejs-packages-${HOST_SHORT_ID}"

# Metrics collection job configuration.
# TODO: Replace placeholder with actual container image URL.
METRICS_JOB_IMAGE="!!!!!!!!!!!!!!!!!"
METRICS_JOB_NAME="metrics-job-${HOST_SHORT_ID}"
METRICS_SCHEDULER_NAME="scheduler-${HOST_SHORT_ID}"
METRICS_JOB_EXECUTE_URL="https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${LOCATION}/jobs/${METRICS_JOB_NAME}:run"

# Agent Cloud Run service configuration.
# TODO: Replace placeholder with actual container image URL.
AGENT_RUN_SERVICE_NAME="agent-${HOST_SHORT_ID}"
GCP_AGENT_IMAGE="!!!!!!!!!!!!!!!!!"

# Workflow helper Cloud Run service configuration.
# This service assists with deployment workflows.
# TODO: Replace placeholder with actual container image URL.
WORKFLOW_HELPER_RUN_SERVICE_NAME="workflow-helper-${HOST_SHORT_ID}"
GCP_WORKFLOW_HELPER_IMAGE="!!!!!!!!!!!!!!!!!"

# Workflow configuration for application deployment.
# This workflow orchestrates the deployment process for applications.
AGENT_DEPLOY_APP_WORKFLOW_NAME="agent-deploy-app-workflow-${HOST_SHORT_ID}"
AGENT_DEPLOY_APP_WORKFLOW=projects/$PROJECT_ID/locations/$LOCATION/workflows/$AGENT_DEPLOY_APP_WORKFLOW_NAME

# ==============================================================================
# INFRASTRUCTURE PROVISIONING (IDEMPOTENT)
# ==============================================================================

# ------------------------------------------------------------------------------
# Enable Required GCP Services
# ------------------------------------------------------------------------------
# Activate all necessary GCP APIs for the project.
# This operation is idempotent; already enabled services are skipped.
echo "Enabling required GCP services..."
gcloud services enable "${GCP_SERVICES[@]}"
echo "✓ All required services are enabled."

# ------------------------------------------------------------------------------
# Service Account Creation and IAM Role Binding
# ------------------------------------------------------------------------------

# Check if the service account already exists to avoid duplication.
SERVICE_ACCOUNT=$(gcloud iam service-accounts list \
    --project="$PROJECT_ID" \
    --filter="displayName:$SERVICE_ACCOUNT_NAME" \
    --format="value(email)")

if [ -n "$SERVICE_ACCOUNT" ]; then
    echo "✓ Service account already exists: $SERVICE_ACCOUNT"
else
    echo "Creating service account: $SERVICE_ACCOUNT_NAME"
    
    # Create a new service account for the BlueForge agent.
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
        --display-name="$SERVICE_ACCOUNT_NAME" \
        --project="$PROJECT_ID"

    # Retrieve the email address of the newly created service account.
    SERVICE_ACCOUNT=$(gcloud iam service-accounts list \
        --project="$PROJECT_ID" \
        --filter="displayName:$SERVICE_ACCOUNT_NAME" \
        --format="value(email)")

    echo "✓ Service account created: $SERVICE_ACCOUNT"
fi

# Assign necessary IAM roles to the service account.
# Each role binding is checked for existence before creation to ensure idempotency.
for ROLE in "${IAM_ROLES[@]}"; do
    echo "Verifying IAM binding for role: $ROLE..."

    # Query existing IAM policy to check if the role is already bound.
    EXISTING_BINDING=$(gcloud projects get-iam-policy "$PROJECT_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.role:$ROLE AND bindings.members:serviceAccount:$SERVICE_ACCOUNT" \
        --format="value(bindings.role)")

    if [ "$EXISTING_BINDING" == "$ROLE" ]; then
        echo "✓ Role $ROLE already assigned to $SERVICE_ACCOUNT"
    else
        echo "Granting role $ROLE to $SERVICE_ACCOUNT..."
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SERVICE_ACCOUNT" \
            --role="$ROLE"
        echo "✓ Role granted successfully."
    fi
done

# ------------------------------------------------------------------------------
# Cloud Storage Bucket Creation
# ------------------------------------------------------------------------------

# Helper function to create uniquely named Cloud Storage buckets.
# If a bucket with the base name exists, it increments a suffix until a unique name is found.
#
# Args:
#   $1: Base name for the bucket (without host ID or increment)
#
# Returns:
#   The name of the created or existing bucket
create_bucket () {
    NAME=$1
    INCREMENT=0
    BUCKET=""
    
    # Loop until a unique bucket name is found or an existing one is returned.
    while [ -z "$BUCKET" ];
    do
        BUCKET_NAME="${NAME}-${HOST_SHORT_ID}-${INCREMENT}"
        BUCKET=$(gcloud storage buckets list --filter="name=${BUCKET_NAME}" --format="value(name)")
        
        if [ -z "$BUCKET" ]; then
            # Attempt to create the bucket; ignore errors if it was created concurrently.
            gcloud storage buckets create "gs://${BUCKET_NAME}" --no-user-output-enabled || true
            BUCKET=$(gcloud storage buckets list --filter="name=${BUCKET_NAME}" --format="value(name)")
        fi
        INCREMENT=$((INCREMENT+1))
    done
    echo $BUCKET
}

# Create bucket for storing deployment plans.
PLANS_BUCKET=$(create_bucket plans)
echo "✓ Plans bucket: ${PLANS_BUCKET}"

# Create bucket for storing archived services.
SERVICES_ARCHIVE_BUCKET=$(create_bucket services-archive)
echo "✓ Services archive bucket: ${SERVICES_ARCHIVE_BUCKET}"

# Create bucket for storing service-related files.
SERVICES_FILES_BUCKET=$(create_bucket services-files)
echo "✓ Services files bucket: ${SERVICES_FILES_BUCKET}"

# Create bucket for storing archived resources.
RESOURCES_ARCHIVE_BUCKET=$(create_bucket resources-archive)
echo "✓ Resources archive bucket: ${RESOURCES_ARCHIVE_BUCKET}"

# ------------------------------------------------------------------------------
# Firestore Database Setup
# ------------------------------------------------------------------------------

# Create a Firestore database in native mode if it doesn't already exist.
# This is the primary datastore for the agent's operational data.
if gcloud firestore databases describe --database="${AGENT_DATABASE_NAME}" --format=none; then
    echo "✓ Using existing Firestore database: ${AGENT_DATABASE_NAME}"
else
    echo "Creating Firestore database: ${AGENT_DATABASE_NAME}..."
    gcloud firestore databases create \
        --database="${AGENT_DATABASE_NAME}" \
        --location="${LOCATION}" \
        --format=none
    echo "✓ Database created successfully."
fi

# Create composite indexes for the 'deployments' collection to optimize queries.
# These indexes support queries that filter by state and sort by creation time.
INDEX_EXISTS=$(gcloud firestore indexes composite list \
    --database="${AGENT_DATABASE_NAME}" \
    --filter="COLLECTION_GROUP:deployments" \
    --format="value(state)")

if [[ -n "$INDEX_EXISTS" ]]; then
    echo "✓ Composite indexes already exist for 'deployments' collection"
else
    echo "Creating composite indexes for 'deployments' collection..."
    
    # Index for ascending createdAt queries (e.g., oldest first).
    gcloud firestore indexes composite create \
        --database="${AGENT_DATABASE_NAME}" \
        --collection-group=deployments \
        --field-config=field-path=state,order=ascending \
        --field-config=field-path=createdAt,order=ascending

    # Index for descending createdAt queries (e.g., newest first).
    gcloud firestore indexes composite create \
        --database="${AGENT_DATABASE_NAME}" \
        --collection-group=deployments \
        --field-config=field-path=state,order=ascending \
        --field-config=field-path=createdAt,order=descending

    echo "✓ Composite indexes created successfully."
fi

# ------------------------------------------------------------------------------
# Artifact Registry Repository Setup
# ------------------------------------------------------------------------------

# Create an npm-format Artifact Registry repository for Node.js packages.
# This repository stores private npm packages used by the agent.
if gcloud artifacts repositories describe "${NODEJS_PACKAGES_REPOSITORY_NAME}" --location="${LOCATION}" --format=none; then
    echo "✓ Using existing Artifact Registry repository: ${NODEJS_PACKAGES_REPOSITORY_NAME}"
else
    echo "Creating Artifact Registry repository for Node.js packages..."

    gcloud artifacts repositories create "${NODEJS_PACKAGES_REPOSITORY_NAME}" \
        --repository-format=npm \
        --location="${LOCATION}" \
        --description="Node.js packages for host ${HOST_ID}"

    echo "✓ Repository created: ${NODEJS_PACKAGES_REPOSITORY_NAME}"
fi

# ------------------------------------------------------------------------------
# Cloud Run Job: Metrics Collection
# ------------------------------------------------------------------------------

# Deploy a Cloud Run job that collects and processes metrics data.
# This job is triggered on a schedule by Cloud Scheduler.
echo "Deploying metrics collection Cloud Run job..."
gcloud run jobs deploy $METRICS_JOB_NAME \
    --image $METRICS_JOB_IMAGE \
    --region $LOCATION \
    --command="/bin/bash" \
    --args=-c,"node job.js" \
    --service-account $SERVICE_ACCOUNT \
    --set-env-vars="AGENT_DATABASE_NAME=${AGENT_DATABASE_NAME}"

echo "✓ Metrics job deployed: ${METRICS_JOB_NAME}"

# Create or update a Cloud Scheduler job to trigger the metrics collection.
# Schedule: Every hour at 5 minutes past the hour (5 * * * *).
if gcloud scheduler jobs describe "$METRICS_SCHEDULER_NAME" --location="$LOCATION" --project="$PROJECT_ID" --format=none; then
    echo "Updating existing Cloud Scheduler job: ${METRICS_SCHEDULER_NAME}..."
    gcloud scheduler jobs update http "$METRICS_SCHEDULER_NAME" \
        --schedule="5 * * * *" \
        --http-method=POST \
        --uri="$METRICS_JOB_EXECUTE_URL" \
        --oauth-service-account-email="$SERVICE_ACCOUNT" \
        --location="$LOCATION" \
        --project="$PROJECT_ID"
    echo "✓ Scheduler job updated."
else
    echo "Creating Cloud Scheduler job: ${METRICS_SCHEDULER_NAME}..."
    gcloud scheduler jobs create http "$METRICS_SCHEDULER_NAME" \
        --schedule="5 * * * *" \
        --http-method=POST \
        --uri="$METRICS_JOB_EXECUTE_URL" \
        --oauth-service-account-email="$SERVICE_ACCOUNT" \
        --location="$LOCATION" \
        --project="$PROJECT_ID"
    echo "✓ Scheduler job created."
fi

# ------------------------------------------------------------------------------
# Cloud Run Services: Workflow Helper and Agent
# ------------------------------------------------------------------------------

# Deploy the workflow helper service.
# This service provides utility endpoints for workflow execution and management.
echo "Deploying workflow helper Cloud Run service..."
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

echo "✓ Workflow helper service deployed: ${WORKFLOW_HELPER_RUN_SERVICE_NAME}"

# Deploy the main agent service.
# This service handles agent operations and orchestrates deployments.
echo "Deploying agent Cloud Run service..."
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

echo "✓ Agent service deployed: ${AGENT_RUN_SERVICE_NAME}"

# Retrieve the public URLs of the deployed Cloud Run services.
# These URLs are used for service communication and workflow configuration.
WORKFLOW_HELPER_HOST_URL=$(gcloud run services describe $WORKFLOW_HELPER_RUN_SERVICE_NAME --region="${LOCATION}" --format="value(url)")
WORKFLOW_HELPER_HOST_URL_SED=$(echo "$WORKFLOW_HELPER_HOST_URL" | sed 's/\//\\\//g')

AGENT_HOST_URL=$(gcloud run services describe $AGENT_RUN_SERVICE_NAME --region="${LOCATION}" --format="value(url)")
AGENT_HOST_URL_SED=$(echo "$AGENT_HOST_URL" | sed 's/\//\\\//g')

echo "✓ Agent URL: ${AGENT_HOST_URL}"
echo "✓ Workflow Helper URL: ${WORKFLOW_HELPER_HOST_URL}"

# ------------------------------------------------------------------------------
# Workflow Deployment
# ------------------------------------------------------------------------------

# Generate the workflow configuration by substituting placeholders in the template.
# The workflow orchestrates multi-step deployment processes.
echo "Generating workflow configuration from template..."
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
    ./WorkflowTemplate.yaml > Workflow.yaml

# Deploy the workflow to Cloud Workflows.
echo "Deploying Cloud Workflow: ${AGENT_DEPLOY_APP_WORKFLOW_NAME}..."
gcloud workflows deploy $AGENT_DEPLOY_APP_WORKFLOW_NAME \
    --source=./Workflow.yaml \
    --location="$LOCATION" \
    --service-account="$SERVICE_ACCOUNT" \
    --format=none

# Clean up temporary workflow file.
rm ./Workflow.yaml

echo "✓ Workflow deployed successfully."

# ------------------------------------------------------------------------------
# Output Results
# ------------------------------------------------------------------------------
echo ""
echo "================================================================================"
echo "✓ Infrastructure setup complete!"
echo "================================================================================"

# Output the agent URL to stdout for Cloud Build to capture.
# This value will be processed by the Cloud Build YAML step.
echo "${AGENT_HOST_URL}"