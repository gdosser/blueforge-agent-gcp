// TODO make this in a separeted functions
// in order to not mix the API with this

import { Storage } from '@google-cloud/storage';
import AdmZip from 'adm-zip';
import { promises as fs } from 'fs';
import request from 'request';
import { v4 as uuid } from 'uuid';
import { parse } from 'yaml';
import { getOutputs, getStateArchitecture } from './App.js';
import { getSteps } from './DeploymentSteps.js';
import Errors from './Errors.js';
import { db, FieldValue } from './Firebase.js';
import { getGcpClient, iam } from './GcpApi.js';

const PROJECT_ID = process.env.PROJECT_ID;
const PLANS_BUCKET = process.env.PLANS_BUCKET;
const SERVICES_ARCHIVE_BUCKET = process.env.SERVICES_ARCHIVE_BUCKET;
const RESOURCES_ARCHIVE_BUCKET = process.env.RESOURCES_ARCHIVE_BUCKET;

const storage = new Storage();

/**
 * 
 * @param {*} param0 
 */
const handleRequest = async ({ appId, planId }) => {
    // get the request object
    const request = await storage
        .bucket(PLANS_BUCKET)
        .file(`${appId}/${planId}/request.json`)
        .download().then(str => JSON.parse(str));

    // download the architecture
    await downloadArchitecture(appId, planId, request.architecture);
    // download the service and resource artifacts
    if (request.artifacts) await downloadArtifacts(request.artifacts);

    // return the masterActions
    return {
        masterActions: request.masterActions
    }
}

/**
 * 
 * @param {*} appId 
 * @param {*} planId 
 * @param {*} architecture // signedUrl 
 * @returns 
 */
const downloadArchitecture = (appId, planId, architecture) => {
    const file = storage.bucket(PLANS_BUCKET).file(`${appId}/${planId}/architecture.json`);
    return uploadFromUrl(file, architecture);
}

/**
 * 
 * @param {*} appId 
 * @param {*} planId 
 * @returns 
 */
const getPlanArchitecture = (appId, planId) => {
    return storage
        .bucket(PLANS_BUCKET)
        .file(`${appId}/${planId}/architecture.json`)
        .download().then(str => JSON.parse(str));
}

/**
 * 
 * @param {*} artifacts 
 * @returns 
 */
const downloadArtifacts = artifacts => {
    return Promise.all(artifacts.map(({ type, name, url, crc32c }) => {
        let bucket;
        if (type == 'service') bucket = SERVICES_ARCHIVE_BUCKET;
        else if (type == 'resource') bucket = RESOURCES_ARCHIVE_BUCKET;
        else throw Errors.INVALID('Invalid artifact type ' + type);
        const file = storage.bucket(bucket).file(`${name}.zip`);
        return file.exists().then(([exists]) => {
            if (!exists) return uploadFromUrl(file, url);
            return file.getMetadata().then(([metadata]) => {
                if (metadata.crc32c != crc32c) return uploadFromUrl(file, url, crc32c);
            });
        });
    }));
}

/**
 * 
 * @param {*} blob 
 * @param {*} url 
 * @param {*} crc32 
 * @returns 
 */
// TODO request is deprecated .. need to use native http or maybe fetch ?
const uploadFromUrl = (blob, url, crc32) => {
    return new Promise((resolve, reject) => {
        request.head(url, (err, res, body) => {
            request(url)
                .pipe(blob.createWriteStream())
                .on('close', () => {
                    blob.getMetadata().then(([metadata]) => {
                        if (metadata.crc32 == crc32) resolve();
                        else reject('Crc32 does not match.');
                    });
                });
        });
    });
}

/**
 * 
 * @param {*} param0 
 * @returns 
 */
const computeDeploymentSteps = ({ appId, planId }) => {
    return Promise.all([
        getStateArchitecture(appId),
        getPlanArchitecture(appId, planId),
    ]).then(([stateArchi, planArchi]) => {
        // the deployment steps 
        const steps = getSteps(stateArchi, planArchi);
        // Flatten steps into a map keyed by stepId
        const allSteps = steps.flat().reduce((acc, step) => {
            acc[step.stepId] = step;
            return acc;
        }, {});
        // store the plan in Firestore
        return db.collection('apps')
            .doc(encodeURIComponent(appId))
            .collection('plans')
            .doc(planId)
            .update({
                steps: allSteps
            }).then(() => {
                return steps
            })
    });
}


/**
 * 
 * @param {*} param0 
 * @returns 
 * 
 */
const updateState = ({ appId, type, id, action, status, deploying, deployed, output, error }) => {

    // delete the resource/layers .. if the delete action is done.
    if (action === 'delete' && status === 'deployed') {
        return db.collection('apps')
            .doc(encodeURIComponent(appId))
            .collection(type)
            .doc(encodeURIComponent(id))
            .delete();
    }

    const updatedAt = Date.now();

    const json = {
        id, type, updatedAt,
    };

    if (status) json.status = status;
    if (deployed) json.deployed = deployed;
    if (output) json.output = output;

    if (deploying === null) json.deploying = FieldValue.delete();
    else if (deploying) json.deploying = deploying;

    if (error === null) json.error = FieldValue.delete();
    else if (error) json.error = error;

    return db.collection('apps')
        .doc(encodeURIComponent(appId))
        .collection(type)
        .doc(encodeURIComponent(id))
        .set(json, { merge: true });

}

/**
 * 
 * @param {*} param0 
 * @returns 
 */
const getAppOutputs = ({ appId }) => {
    return getOutputs(appId);
}

/**
 * progress (started / finished)
 * @param {*} param0 
 * @returns 
 */
const setStepStatus = ({ appId, planId, stepId, progress, status }) => {
    return db.collection('apps')
        .doc(encodeURIComponent(appId))
        .collection('plans')
        .doc(planId).update({
            [`steps.${stepId}.${progress}`]: Date.now(),
            [`steps.${stepId}.status`]: status,
        })
}

const getServiceDeployYaml = async ({ artifact }) => {
    console.log('>>>>>>>' + artifact)
    const localZipPath = uuid();
    try {
        // Step 1: Download the ZIP file from the GCS bucket
        await storage.bucket(SERVICES_ARCHIVE_BUCKET).file(`${artifact}.zip`).download({ destination: localZipPath });

        // Step 2: Extract the specified file from the ZIP archive
        const zip = new AdmZip(localZipPath);
        const targetFile = zip.getEntry('deploy.yaml');

        if (!targetFile) {
            throw new Error(`The file deploy.yaml does not exist in the ZIP archive.`);
        }

        // Step 3: Return the content of the extracted file
        const str = targetFile.getData().toString('utf-8');

        // Step 4: parse yaml string to json
        const build = parse(str);

        // we add a step to read all substitutions.
        // we do that because cloud build fails if one substitution is not used.
        // now services can just used substitutions they only need. 
        const readAllSubstitutionStep = {
            name: "gcr.io/google.com/cloudsdktool/cloud-sdk:slim",
            entrypoint: "bash",
            args: [
                "-c",
                `
          echo "PROJECT_ID: \${_PROJECT_ID}"
          echo "LOCATION: \${_LOCATION}"
          echo "SERVICE_ACCOUNT: \${_SERVICE_ACCOUNT}"
          echo "HOST_ID: \${_HOST_ID}"
          echo "HOST_SHORT_ID: \${_HOST_SHORT_ID}"
          echo "APP_ID: \${_APP_ID}"
          echo "APP_SHORT_ID: \${_APP_SHORT_ID}"
          echo "PLAN_ID: \${_PLAN_ID}"
          echo "SERVICES_FILES_BUCKET: \${_SERVICES_FILES_BUCKET}"
          echo "RESOURCES_ARCHIVE_BUCKET: \${_RESOURCES_ARCHIVE_BUCKET}"
              `
            ]
        }

        build.steps = [readAllSubstitutionStep, build.steps]

        // set default timeout
        if (!build.timeout) build.timeout = '1200s';

        return build;
    } catch (error) {
        console.error(`Error: ${error.message}`);
        return null;
    } finally {
        // Cleanup: Remove the temporary ZIP file
        try {
            await fs.unlink(localZipPath);
            console.log(`Temporary file "${localZipPath}" removed.`);
        } catch (cleanupError) {
            console.warn(`Failed to remove temporary file: ${cleanupError.message}`);
        }
    }
}

/**
 * 
 * @param {*} param0 
 * @returns 
 */
const createResourceShortId = async ({ appId, appShortId }) => {
    const appRef = db.collection('apps').doc(encodeURIComponent(appId));
    await appRef.update({ _counter: FieldValue.increment(1) });
    const doc = await appRef.get();
    const app = doc.data();
    return {
        shortId: `${appShortId}-${app._counter}`,
    };
}

/**
 * 
 * @param {*} param0 
 * @returns 
 */
const deleteResourceShortId = async ({ appId, appShortId }) => {
    // noop
}

/**
 * account must be created one by one not in // (there is a limit on the number of account creation per minute on GCP)
 * @param {*} param0 
 * @returns 
 */
const createModuleAccount = async ({ moduleId, outputs }) => {
    const shortId = outputs.ids[moduleId]?.shortId;
    if (!shortId) {
        throw new Errors.INVALID(`Uid not created for the module ${moduleId}.`);
    }

    const authClient = await getGcpClient();

    const request = {
        name: `projects/${PROJECT_ID}`,
        resource: {
            accountId: `account-${shortId}`,
            serviceAccount: {
                description: `Service Account for the following moduleId:${moduleId}).`,
                displayName: `Generated Service Account`,
            }
        },
        auth: authClient,
    };

    const result = await iam.projects.serviceAccounts.create(request);
    const email = result.data?.email;

    await new Promise(r => setTimeout(r, 15000)); // quota is 5 max per minute

    return { account: `serviceAccount:${email}` };
};


/**
 * 
 * @param {*} param0 
 * @returns 
 */
const deleteModuleAccount = async ({ moduleId, outputs }) => {
    const rawAccount = outputs?.accounts?.[moduleId]?.account;

    if (!rawAccount || typeof rawAccount !== 'string') {
        throw new Error(`Invalid or missing service account for moduleId: ${moduleId}`);
    }

    if (!rawAccount.startsWith("serviceAccount:")) {
        throw new Error(`Account "${rawAccount}" does not start with 'serviceAccount:'`);
    }

    const email = rawAccount.slice("serviceAccount:".length);

    try {
        const authClient = await getGcpClient();

        const request = {
            name: `projects/${PROJECT_ID}/serviceAccounts/${email}`,
            auth: authClient,
        };

        await iam.projects.serviceAccounts.delete(request);

        console.log(`Service account ${email} deleted successfully`);

    } catch (err) {
        if (err.code === 404) {
            console.warn(`Service account ${email} already deleted or not found`);
        } else {
            console.error(`Failed to delete service account ${email}:`, err.message);
            throw err;
        }
    }
};


/**
 * 
 * @param {*} param0 
 * @returns 
 */
const updateStatus = ({ appId, planId, status, error }) => {
    const appRef = db.collection('apps').doc(encodeURIComponent(appId));
    const planRef = appRef.collection('plans').doc(planId);

    const appUpdate = { status };
    if (status === 'deployed') {
        appUpdate.deployed = planId;
        appUpdate.deploying = []
    }

    const planUpdate = {
        status,
        error,
    }

    const batch = db.batch();
    batch.update(appRef, appUpdate);
    batch.update(planRef, planUpdate);
    return batch.commit();
}

/**
 * 
 * @param {*} param0 
 * @returns 
 */
const getLayerPackageName = async ({ layerId }) => {
    const [service, layerName] = layerId.split('/');
    let packageName = null;
    if (layerName.endsWith('_service_layer_nodejs')) {
        packageName = `@service/${service}`;
    } else {
        throw new Error(`Layer type not implemented: ${layerId}`);
    }
    return { packageName };
}

/**
 * List of functions used in the workflow.
 */
const WorkflowFunctions = {
    updateState,
    updateStatus,
    handleRequest,
    getAppOutputs,
    computeDeploymentSteps,
    setStepStatus,
    getServiceDeployYaml,
    createResourceShortId,
    deleteResourceShortId,
    createModuleAccount,
    deleteModuleAccount,
    getLayerPackageName,
};

/**
 * 
 * @param {*} functionName 
 * @param {*} payload 
 * @returns 
 */
export const callFunction = (functionName, payload) => {
    const fn = WorkflowFunctions[functionName];
    if (fn) {
        console.log(`Call workflow function '${functionName}' with payload: (${JSON.stringify(payload)})`);
        return fn(payload);
    } else {
        throw Errors.NOT_FOUND(`Step ${functionName} not found`);
    }
}