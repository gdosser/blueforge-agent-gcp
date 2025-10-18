import { db } from './Firebase.js';

/**
 * 
 * @param {*} appId 
 * @param {*} resourceIds 
 * @returns 
 */
export const getResourceOutputs = async (appId, resourceIds) => {
    const outputs = { ids: {}, accounts: {}, resources: {} };
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
