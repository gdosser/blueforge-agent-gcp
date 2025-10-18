import { Storage } from '@google-cloud/storage';
import { ExecutionsClient } from '@google-cloud/workflows';
import { customAlphabet } from 'nanoid';
import { db, FieldValue } from './Firebase.js';

const AGENT_DEPLOY_APP_WORKFLOW = process.env.AGENT_DEPLOY_APP_WORKFLOW;
const PLANS_BUCKET = process.env.PLANS_BUCKET;
const SERVICE_ACCOUNT = process.env.SERVICE_ACCOUNT;

const executionsClient = new ExecutionsClient();
const storage = new Storage();

const nanoid = customAlphabet('abcdefghijklmnopqrstuvwxyz', 3);

/**
 * 
 */
const Status = {
    DEPLOYED: 'deployed',
    DEPLOYING: 'deploying',
    FAILED: 'failed',
}

/**
 * Generate a short id for the app that is unique in this host
 * 100 tries, then fails
 * @returns 
 */
export const generateAppShortId = async (transaction) => {
    let i = 0;
    let result = null;
    while (i++ < 100 && !result) {
        let appShortId = nanoid();
        const ref = db.collection('apps').where('appShortId', '==', appShortId);
        const qs = await transaction.get(ref);
        if (qs.empty) result = appShortId;
    }
    if (!result) throw new Error('Unable to create a app short id.');
    return result;
}

/**
 * 
 * @param {*} appId 
 * @param {*} deploymentId 
 * @param {*} architecture 
 * @param {*} artifacts 
 * @param {*} masterActions 
 * @returns 
 */
export const putApp = async (appId, deploymentId, architecture, artifacts, masterActions) => {
    const appDatabaseId = encodeURIComponent(appId);
    const appRef = db.collection('apps').doc(appDatabaseId);
    let deployment = null;

    await db.runTransaction(async transaction => {
        const doc = await transaction.get(appRef);
        const app = doc.exists ? doc.data() : null;

        const request = {
            appId, deploymentId, architecture, artifacts, masterActions
        }

        await storage.bucket(PLANS_BUCKET).file(`${appId}/${deploymentId}/request.json`).save(
            JSON.stringify(request, null, 2),
            { contentType: 'application/json', resumable: false }
        );

        // get or create the appShortId
        const appShortId = app ? app._appShortId : await generateAppShortId(transaction);

        await executionsClient.createExecution({
            parent: AGENT_DEPLOY_APP_WORKFLOW,
            execution: {
                // Note: there is a limit in the argument size (32kb I think).
                argument: JSON.stringify({
                    serviceAccount: SERVICE_ACCOUNT,
                    appId,
                    appShortId,
                    planId
                })
            }
        });

        const planRef = appRef.collection('plans').doc(planId);

        // create the deployement
        deployment = {
            appId,
            planId,
            deployedAt,
            status: Status.DEPLOYING,
        }
        if (deploymentPoint) plan.deploymentPoint = deploymentPoint;
        transaction.set(planRef, plan);

        // create or update the app
        if (!app) {
            transaction.set(appRef, {
                appId,
                _appShortId: appShortId,
                deployedAt,
                deploying: [planId],
                status: Status.DEPLOYING,
            });
        } else {
            transaction.update(appRef, {
                deployedAt,
                deploying: FieldValue.arrayUnion(planId),
                status: Status.DEPLOYING,
            });
        };
    });
    return plan;
}


/**
 * return the state of the app
 * @param {*} appId 
 * @returns 
 */
export const getApp = appId => {
    const appDatabaseId = encodeURIComponent(appId);
    const appRef = db.collection('apps').doc(appDatabaseId);
    return db.runTransaction(transaction => {

        const getApp = () => transaction.get(appRef).then(doc => {
            if (!doc.exists) return null;
            // return the app (filter private fields starting by _)
            return Object.fromEntries(Object.entries(doc.data()).filter(([k]) => !k.startsWith('_')));
        });

        const getState = type => transaction.get(appRef.collection(type)).then(qs => {
            if (qs.empty) return {};
            const elements = {};
            qs.forEach(doc => {
                const data = doc.data();
                elements[data.id] = data;
            });
            return elements;
        });

        return Promise.all([
            getApp(),
            getState('resources'),
            getState('services'),
            getState('layers'),
        ]).then(([app, resources, services, layers]) => {
            if (!app) return null;
            else {
                const json = {
                    appId: app.appId,
                    hostProvider: 'gcp',
                    deployedAt: app.deployedAt,
                    deployed: app.deployed, // deployed planId
                    status: app.status,
                    resources,
                    services,
                    layers,
                    now: Date.now(),
                }
                if (app.deploying) json.deploying = app.deploying; // deploying planId
                return json
            }
        });
    });
}

/**
 * 
 * @param {*} appId 
 * @param {*} resourceId 
 * @returns 
 */
export const getAppResource = async (appId, resourceId) => {
    const appDatabaseId = encodeURIComponent(appId);
    const appRef = db.collection('apps').doc(appDatabaseId);
    const resourceRef = appRef.collection('resources').doc(encodeURIComponent(resourceId));
    const doc = await resourceRef.get();
    if (!doc.exists) throw new Error(`Resource ${resourceId} do not exist.`);
    return Object.fromEntries(Object.entries(doc.data()).filter(([k]) => !k.startsWith('_')));
}

/**
 * 
 * @param {*} appId 
 * @param {*} planId 
 * @returns 
 */
export const getAppPlan = (appId, planId) => {
    const appDatabaseId = encodeURIComponent(appId);
    const appRef = db.collection('apps').doc(appDatabaseId);
    const planRef = appRef.collection('plans').doc(planId);
    return planRef.get().then(doc => {
        if (!doc.exists) return null;
        const result = Object.fromEntries(Object.entries(doc.data()).filter(([k]) => !k.startsWith('_')));
        result.now = Date.now(); // TODO ca sert a quoi ca ?
        return result;
    });
}

/**
 * return the state of the app
 * @param {*} appId 
 * @param {*} types ex: ['services', 'layers', 'resources']
 * @returns 
 */
export const getStateArchitecture = (appId, types) => {
    if (!types) types = ['ids', 'accounts', 'services', 'layers', 'resources'];
    const appDatabaseId = encodeURIComponent(appId);
    const appRef = db.collection('apps').doc(appDatabaseId);
    return db.runTransaction(transaction => {

        const getState = type => transaction.get(appRef.collection(type)).then(qs => {
            if (qs.empty) return {};
            const elements = {};
            qs.forEach(doc => {
                const { id, deployed } = doc.data();
                if (deployed) elements[id] = deployed;
            });
            return elements;
        });

        return Promise.all(types.map(type => getState(type).then(elements => [type, elements])))
            .then(entries => Object.fromEntries(entries))
    });
}

/**
 * Fetch outputs from a given app in Firestore.
 *
 * @param {string} appId - ID of the application
 * @param {Object} [options]
 * @param {string[]} [options.types=['ids','accounts','services','layers','resources']] - Sub-collection types to query
 * @param {string[]} [options.resourceIds] - Optional list of resource IDs. If provided, only these docs will be fetched.
 * @returns {Promise<Object>} - An object with outputs grouped by type (and resourceId if applicable)
 */
export const getOutputs = async (appId, { types, resourceIds } = {}) => {
    // Default sub-collections if none provided
    const defaultTypes = ['ids', 'accounts', 'services', 'layers', 'resources'];
    const selectedTypes = types && types.length > 0 ? types : defaultTypes;

    // Reference to the app document
    const appRef = db.collection('apps').doc(encodeURIComponent(appId));

    // Initialize outputs structure: { type1: {}, type2: {}, ... }
    const outputs = Object.fromEntries(selectedTypes.map(type => [type, {}]));

    /**
     * Fetch data for a single type.
     * - If resourceIds are provided, fetch only those docs.
     * - Otherwise, fetch the entire collection.
     */
    const getState = async (type) => {
        if (resourceIds && resourceIds.length > 0) {
            // Case 1: Specific resource IDs requested
            await Promise.all(
                resourceIds.map(async (resourceId) => {
                    const docRef = appRef.collection(type).doc(encodeURIComponent(resourceId));
                    const doc = await docRef.get();

                    if (doc.exists) {
                        const { output } = doc.data();
                        outputs[type][resourceId] = output;
                    }
                })
            );
        } else {
            // Case 2: Fetch entire collection
            const snapshot = await appRef.collection(type).get();
            snapshot.forEach((doc) => {
                const { output } = doc.data();
                const id = decodeURIComponent(doc.id);
                if (output) outputs[type][id] = output;
            });
        }
    };

    // Fetch all selected types in parallel
    await Promise.all(selectedTypes.map(getState));

    return outputs;
};

/*
export const getOutputs = (appId, types) => {
    if (!types) types = ['ids', 'accounts', 'services', 'layers', 'resources'];
    const appRef = db.collection('apps').doc(encodeURIComponent(appId));
    const getState = type => {
        return appRef.collection(type).get().then(qs => {
            const elements = {};
            qs.forEach(doc => {
                const { output } = doc.data();
                const id = decodeURIComponent(doc.id);
                if (output) elements[id] = output;
            });
            return elements;
        });
    }
    return Promise.all(types.map(type => getState(type).then(elements => [type, elements])))
        .then(entries => Object.fromEntries(entries));
}

export const getResourceOutputs = async (appId, resourceIds, types) => {
    if (!types) types = ['ids', 'accounts', 'services', 'layers', 'resources'];
    const outputs = Object.fromEntries(types.map(type => [type, {}]));
    const appRef = db.collection('apps').doc(encodeURIComponent(appId));
    const getState = async (type, resourceId) => {
        const doc = await appRef.collection(type).doc(encodeURIComponent(resourceId)).get();
        if (doc.exists) {
            const { output } = doc.data();
            outputs[type][resourceId] = output;
        }
    }
    await Promise.all(Object.keys(outputs).flatMap(type => resourceIds.map(resourceId => getState(type, resourceId))));
    return outputs;
}
*/