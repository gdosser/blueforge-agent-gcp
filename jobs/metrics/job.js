import { db } from './Firebase.js';
import { getMetric } from './Metrics.js';

console.log("✅ Hello from Cloud Run Job!");

// Split an array into smaller chunks (default size = 10)
const chunkArray = (arr, size = 10) => {
    const result = [];
    for (let i = 0; i < arr.length; i += size) {
        result.push(arr.slice(i, i + size));
    }
    return result;
};

// Round timestamp (in ms) to the last full hour
const roundToFullHour = (timestamp) => {
    const date = new Date(timestamp);
    date.setMinutes(0, 0, 0);
    return date.getTime();
};

const now = roundToFullHour(Date.now());
const threeDaysAgo = roundToFullHour(now - 3 * 24 * 60 * 60 * 1000);

// Retrieve all apps from Firestore
const listApps = async () => {
    const appsSnap = await db.collection('apps').get();
    return appsSnap.docs.map(doc => doc.data());
};

// Fetch and store metrics for a single app
const fetchMetrics = async app => {
    const appId = app.appId;
    const endTime = now / 1000;
    const appRef = db.collection('apps').doc(encodeURIComponent(appId));

    console.log(`📊 Fetching metrics for app ${appId}`);

    // Collect deployed services and their resource IDs
    const resourcesSnap = await appRef.collection('resources').get();
    const servicesResources = {};
    resourcesSnap.forEach((doc) => {
        const resource = doc.data();
        const serviceId = resource?.deployed?.service;
        if (serviceId) {
            if (!servicesResources[serviceId]) servicesResources[serviceId] = [];
            servicesResources[serviceId].push(resource.id);
        }
    });

    // Load metrics enabled per service
    const servicesMetricsEntries = await Promise.all(
        Object.keys(servicesResources).map(async (serviceId) => {
            const doc = await appRef.collection('services').doc(serviceId).get();
            if (!doc.exists) return [serviceId, null];
            return [serviceId, doc.data()?.deployed?.cachedMetrics];
        })
    );
    const servicesMetrics = Object.fromEntries(servicesMetricsEntries.filter(([_, m]) => m != null));

    console.log('✅✅ servicesMetrics', JSON.stringify(servicesMetrics))


    const timeseries = [];

    // For each service, fetch all enabled metrics
    await Promise.all(Object.entries(servicesResources)
        .filter(([serviceId]) => servicesMetrics[serviceId])
        .map(async ([serviceId, resourceIds]) => {
            const metrics = servicesMetrics[serviceId];
            const chunks = chunkArray(resourceIds, 10);

            await Promise.all(metrics.map(async (metric) => {
                const startTime = app.metricsLastFetchedAt?.[serviceId] || (threeDaysAgo / 1000);

                const seriesChunks = await Promise.all(
                    chunks.map(chunk =>
                        getMetric(appId, serviceId, metric, {
                            resourceIds: chunk,
                            startTime,
                            endTime,
                            alignmentPeriod: 60 * 60, // 1 hour
                        })
                    )
                );

                seriesChunks.forEach(series => timeseries.push(...series));
            }));
        }));

    console.log('✅✅ timeseries', JSON.stringify(timeseries))


    // Atomic write of all metrics + lastFetched timestamp
    await db.runTransaction(async (transaction) => {
        // Read existing points per resource/metric
        const metricDatas = Object.fromEntries(await Promise.all(
            timeseries.map(async ({ resourceId, metric, label }) => {
                const metricName = label ? `${metric}:${label}` : metric;
                const ref = appRef
                    .collection('resources')
                    .doc(encodeURIComponent(resourceId))
                    .collection('metrics')
                    .doc(metricName);
                const doc = await transaction.get(ref);
                return [`${resourceId}/${metricName}`, doc.exists ? doc.data() : {}];
            })
        ));

        // Merge and filter points
        timeseries.forEach(({ resourceId, metric, label, points }) => {
            const metricName = label ? `${metric}:${label}` : metric;
            const key = `${resourceId}/${metricName}`;
            const prevData = metricDatas[key];
            const existing = prevData.points || [];

            const existingEndTimes = new Set(existing.map(p => p.endTime));
            const newPoints = points.filter(p => !existingEndTimes.has(p.endTime));
            const mergedPoints = [...existing, ...newPoints].filter(p => p.endTime >= threeDaysAgo / 1000);

            const metricRef = appRef
                .collection('resources')
                .doc(encodeURIComponent(resourceId))
                .collection('metrics')
                .doc(metricName);

            const metricData = {
                resourceId,
                metric,
                points: mergedPoints,
            }
            if (label) metricData.label = label;

            transaction.set(metricRef, metricData);
        });

        console.log('✅✅ servicesMetrics 2', JSON.stringify(servicesMetrics))
        console.log('✅✅ Object.keys(servicesMetrics) 2', JSON.stringify(Object.keys(servicesMetrics)))

        // Update metricsLastFetchedAt per service
        const lastFetchedUpdate = Object.fromEntries(
            Object.keys(servicesMetrics).map(serviceId => [`metricsLastFetchedAt.${serviceId}`, endTime])
        );

        console.log('✅✅ lastFetchedUpdate', lastFetchedUpdate)
        transaction.update(appRef, lastFetchedUpdate);
    });

    console.log(`✅ Metrics successfully stored for app: ${appId}`);
};

// Main entry point
const main = async () => {
    const apps = await listApps();
    await Promise.all(apps.map(fetchMetrics));
};

main()
    .then(() => {
        console.log("✅ Job completed successfully");
        process.exit(0);
    })
    .catch(err => {
        console.error("❌ Job failed:", err);
        process.exit(1);
    });