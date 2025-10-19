# BlueForge Agent Host - GCP Infrastructure Setup

## Overview

This repository contains the infrastructure-as-code for provisioning a complete BlueForge agent host environment on Google Cloud Platform (GCP). The setup script creates and configures all necessary cloud resources to run a fully functional agent deployment system.

## What Does This Do?

The setup script provisions a production-ready infrastructure that includes:

### Core Services
- **Agent Service**: Main Cloud Run service that handles agent operations and orchestrates deployments
- **Workflow Helper Service**: Utility service that provides endpoints for workflow execution and management
- **Metrics Collection Job**: Scheduled job that collects and processes operational metrics

### Data Storage
- **Firestore Database**: Native-mode database for storing deployment state, configuration, and operational data
- **Cloud Storage Buckets**:
  - **Plans Bucket**: Stores deployment plans and configurations
  - **Services Archive Bucket**: Contains archived service versions
  - **Services Files Bucket**: Holds service-related files and assets
  - **Resources Archive Bucket**: Stores archived infrastructure resources

### Infrastructure Components
- **Service Account**: Dedicated identity with appropriate IAM permissions for resource management
- **Artifact Registry**: npm repository for private Node.js packages
- **Cloud Workflows**: Orchestrates complex multi-step deployment processes
- **Cloud Scheduler**: Triggers metrics collection on an hourly schedule
- **Composite Indexes**: Optimized Firestore queries for deployment operations

### Enabled GCP APIs
The script automatically enables all required GCP services including:
- Cloud Run, Cloud Build, Cloud Workflows
- Cloud Storage, Firestore, Artifact Registry
- Cloud Scheduler, Eventarc
- Monitoring, Logging, IAM

## Prerequisites

Before running the setup script, ensure you have:

1. **Google Cloud SDK (gcloud)** installed and configured
   ```bash
   gcloud version
   ```

2. **Active GCP Project** with billing enabled
   ```bash
   gcloud config set project YOUR_PROJECT_ID
   ```

3. **Authentication** configured
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

4. **Required IAM Permissions** to create:
   - Service accounts
   - IAM role bindings
   - Cloud Run services and jobs
   - Cloud Storage buckets
   - Firestore databases
   - Workflows
   - Artifact Registry repositories

5. **Container Images** (replace placeholders in script):
   - Agent service image
   - Workflow helper service image
   - Metrics job image

## Usage

### Basic Usage

```bash
./setup.sh \
  --hostId=@default/my-first-host \
  --location=europe-west1 \
  --hostShortId=1ac9d8
```

### Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--hostId` | Fully qualified host identifier (format: `@organization/hostname`) | `@default/production` |
| `--location` | GCP region for resource deployment | `europe-west1` |
| `--hostShortId` | Short unique identifier for this host instance (used in resource naming) | `1ac9d8` |

### Example Commands

**Development Environment:**
```bash
./setup.sh \
  --hostId=@acme/dev-host \
  --location=us-central1 \
  --hostShortId=dev001
```

**Production Environment:**
```bash
./setup.sh \
  --hostId=@acme/prod-host \
  --location=europe-west1 \
  --hostShortId=prod01
```

## Configuration

### Before First Run

1. **Update Container Images**: Replace placeholder image URLs in the script:
   ```bash
   METRICS_JOB_IMAGE="gcr.io/YOUR_PROJECT/metrics-job:latest"
   GCP_AGENT_IMAGE="gcr.io/YOUR_PROJECT/agent:latest"
   GCP_WORKFLOW_HELPER_IMAGE="gcr.io/YOUR_PROJECT/workflow-helper:latest"
   ```

2. **Review IAM Roles**: The script currently uses `roles/owner` for simplicity. For production, replace with least-privilege roles:
   ```bash
   IAM_ROLES=(
       roles/run.admin
       roles/iam.serviceAccountUser
       roles/storage.admin
       roles/firestore.admin
       roles/workflows.admin
   )
   ```

3. **Customize Workflow Template**: Ensure `WorkflowTemplate.yaml` exists in the same directory and contains your workflow definition.

### Idempotency

The script is designed to be **fully idempotent**. You can safely re-run it multiple times:
- Existing resources are detected and reused
- Only missing resources are created
- Updates are applied to existing resources when needed

This makes it safe for:
- Re-running after failures
- Updating configurations
- Adding new resources

## Output

After successful execution, the script outputs:

```json
{
  "AGENT_HOST_URL": "https://agent-1ac9d8-xyz-uc.a.run.app"
}
```

This URL is the public endpoint for your agent service and is also saved to `${BUILDER_OUTPUT}/output`.

### Viewing Resources

**List Cloud Run Services:**
```bash
gcloud run services list --region=europe-west1
```

**View Firestore Database:**
```bash
gcloud firestore databases describe --database=agent-db-1ac9d8
```

**Check Cloud Storage Buckets:**
```bash
gcloud storage buckets list --filter="name~1ac9d8"
```

**View Scheduled Jobs:**
```bash
gcloud scheduler jobs list --location=europe-west1
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     External Requests                        │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
                  ┌─────────────────┐
                  │  Agent Service  │ (Cloud Run)
                  │  Public Access  │
                  └────────┬────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌──────────┐   ┌─────────────┐  ┌──────────┐
    │Firestore │   │  Workflows  │  │ Storage  │
    │ Database │   │             │  │ Buckets  │
    └──────────┘   └──────┬──────┘  └──────────┘
                          │
                          ▼
                ┌──────────────────┐
                │ Workflow Helper  │ (Cloud Run)
                │ Private Access   │
                └──────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                    Scheduled Operations                       │
├──────────────────────────────────────────────────────────────┤
│  Cloud Scheduler → Metrics Job (Cloud Run Job)              │
│  Runs hourly at :05 minutes                                 │
└──────────────────────────────────────────────────────────────┘
```

## Resource Naming Convention

All resources follow a consistent naming pattern:

```
{resource-type}-{host-short-id}-{increment}
```

Examples:
- `agent-1ac9d8` (Cloud Run service)
- `agent-db-1ac9d8` (Firestore database)
- `plans-1ac9d8-0` (Storage bucket)
- `metrics-job-1ac9d8` (Cloud Run job)

This convention:
- Prevents naming conflicts
- Enables easy identification of related resources
- Supports multiple host instances in the same project

## Security Considerations

### Service Account Permissions

⚠️ **Important**: The script currently grants `roles/owner` to the service account. This is **not recommended for production**. 

**TODO**: Implement least-privilege access with specific roles:
```bash
roles/run.admin                    # Manage Cloud Run services
roles/iam.serviceAccountUser       # Act as service accounts
roles/storage.admin                # Manage storage buckets
roles/firestore.admin              # Manage Firestore
roles/workflows.admin              # Manage workflows
roles/artifactregistry.writer      # Write to Artifact Registry
```

### Network Security

- **Agent Service**: Public access (no authentication required)
- **Workflow Helper**: Private access (requires authentication)
- **Metrics Job**: Triggered only by Cloud Scheduler with service account authentication

### Data Protection

- All buckets are created with default encryption
- Firestore data is encrypted at rest
- Service-to-service communication uses IAM-based authentication

## Monitoring and Operations

### View Logs

**Agent Service Logs:**
```bash
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=agent-1ac9d8" --limit 50
```

**Metrics Job Logs:**
```bash
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=metrics-job-1ac9d8" --limit 50
```

### Check Service Status

```bash
gcloud run services describe agent-1ac9d8 --region=europe-west1
```

### Manual Workflow Execution

```bash
gcloud workflows run agent-deploy-app-workflow-1ac9d8 \
  --location=europe-west1 \
  --data='{"app":"my-app","version":"1.0.0"}'
```

## Troubleshooting

### Common Issues

**1. Permission Denied Errors**
```bash
# Ensure you have the necessary IAM permissions
gcloud projects get-iam-policy YOUR_PROJECT_ID
```

**2. Service Enablement Failures**
```bash
# Manually enable services
gcloud services enable run.googleapis.com
```

**3. Bucket Creation Conflicts**
```bash
# The script handles this automatically with incremental naming
# If issues persist, check existing buckets:
gcloud storage buckets list
```

**4. Workflow Deployment Fails**
```bash
# Verify WorkflowTemplate.yaml exists and is valid YAML
cat WorkflowTemplate.yaml | python -m yaml
```

### Debug Mode

Enable verbose output:
```bash
set -x  # Add to top of script
./setup.sh --hostId=@org/host --location=us-central1 --hostShortId=abc123
```

## Cleanup

To remove all created resources:

```bash
# Delete Cloud Run services
gcloud run services delete agent-1ac9d8 --region=europe-west1 --quiet
gcloud run services delete workflow-helper-1ac9d8 --region=europe-west1 --quiet

# Delete Cloud Run jobs
gcloud run jobs delete metrics-job-1ac9d8 --region=europe-west1 --quiet

# Delete Cloud Scheduler jobs
gcloud scheduler jobs delete scheduler-1ac9d8 --location=europe-west1 --quiet

# Delete workflows
gcloud workflows delete agent-deploy-app-workflow-1ac9d8 --location=europe-west1 --quiet

# Delete Firestore database
gcloud firestore databases delete --database=agent-db-1ac9d8

# Delete storage buckets
gsutil -m rm -r gs://plans-1ac9d8-*
gsutil -m rm -r gs://services-archive-1ac9d8-*
gsutil -m rm -r gs://services-files-1ac9d8-*
gsutil -m rm -r gs://resources-archive-1ac9d8-*

# Delete Artifact Registry repository
gcloud artifacts repositories delete nodejs-packages-1ac9d8 --location=europe-west1 --quiet

# Delete service account
gcloud iam service-accounts delete blueforge@YOUR_PROJECT_ID.iam.gserviceaccount.com --quiet
```

## Cost Estimation

Approximate monthly costs for a typical setup:

| Service | Estimated Cost |
|---------|----------------|
| Cloud Run (agent + helper) | $10-50 |
| Cloud Run Jobs (metrics) | $5-15 |
| Firestore | $5-25 |
| Cloud Storage | $1-10 |
| Cloud Workflows | $1-5 |
| Cloud Scheduler | $0.10 |
| **Total** | **~$22-105/month** |

*Costs vary based on usage, traffic, and data storage.*

## Support

For issues or questions:
- Review GCP documentation: https://cloud.google.com/docs
- Check script logs for detailed error messages
- Verify all prerequisites are met
- Ensure container images are correctly specified

## License

[Specify your license here]

## Contributors

[List contributors or link to CONTRIBUTORS.md]