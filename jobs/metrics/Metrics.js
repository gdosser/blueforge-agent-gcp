import { GoogleAuth } from 'google-auth-library';
import { db } from './Firebase.js';
import { getResourceOutputs } from './App.js';

const auth = new GoogleAuth();

/**
 * Fetches metric data for a given service and resource set from a backend endpoint.
 * 
 * @param {string} appId - The application ID.
 * @param {string} serviceId - The service ID associated with the metrics.
 * @param {string} metric - The metric type to query (e.g., request_count).
 * @param {object} metricOptions - Options for the metric query:
 *   - resourceIds: string[]
 *   - startTime: number (UNIX timestamp in seconds)
 *   - endTime: number (UNIX timestamp in seconds)
 *   - alignmentPeriod: number (in seconds)
 * @returns {Promise<object>} The metric data response from the backend.
 */
export const getMetric = async (appId, serviceId, metric, metricOptions) => {
    // Reference to the service document in Firestore
    const serviceRef = db
        .collection('apps')
        .doc(encodeURIComponent(appId))
        .collection('services')
        .doc(serviceId);

    const doc = await serviceRef.get();
    if (!doc.exists) {
        throw new Error(`Service ${serviceId} does not exist in app ${appId}.`);
    }

    const service = doc.data();
    const serviceUrl = service?.output?.url;
    if (!serviceUrl) {
        throw new Error(`Service ${serviceId} does not have a valid output URL.`);
    }

    const { resourceIds, startTime, endTime, alignmentPeriod } = metricOptions;

    // Retrieve outputs for the provided resource IDs
    const outputs = await getResourceOutputs(appId, resourceIds);

    // Create an authenticated HTTP client with ID token
    const client = await auth.getIdTokenClient(serviceUrl);

    // Send the metric request to the service's /metrics/:metric endpoint
    const res = await client.fetch(`${serviceUrl}/metrics/${metric}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            resourceIds,
            outputs,
            startTime,
            endTime,
            alignmentPeriod,
        }),
    });

    // Check for error response
    if (!res.ok) {
        const text = await res.text(); // read response text to include in error
        throw new Error(`Backend error (${res.status}): ${text}`);
    }

    // Return json
    return res.data;
};   