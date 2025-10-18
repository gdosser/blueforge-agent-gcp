# Config.sh

# GCP project
PROJECT_ID="host-437615"

# Service account name
SERVICE_ACCOUNT_NAME="blueforge"

# Roles to use by the agent
# TODO the agent needs the setIamPolicy role on resource we deploy (Cloud Run for instance).
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