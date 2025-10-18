import { db } from './Firebase.js';

/**
 * Returns cached metric documents for a given resource.
 *
 * If `metric` contains a “:”, it is treated as an exact document ID
 * (e.g. "request_count:2xx") and the function reads that single doc.
 * Otherwise, it queries the `metrics` sub-collection for every document
 * whose `metric` field matches the supplied name (e.g. "request_count").
 *
 * Always resolves to an **array**:
 *   • `[]` when nothing found
 *   • `[doc]` when one matching doc
 *   • `[...docs]` when multiple docs
 *
 * @param {string} appId            – Application identifier.
 * @param {string} resourceId       – Resource identifier.
 * @param {string} metric           – Metric name or metric:label.
 * @returns {Promise<object[]>}
 */
export const getCachedMetric = async (
	appId,
	resourceId,
	metric
) => {
	const metricsCol = db
		.collection('apps')
		.doc(encodeURIComponent(appId))
		.collection('resources')
		.doc(encodeURIComponent(resourceId))
		.collection('metrics');

	// ── Exact-document read ──────────────────────────────────────────────
	if (metric.includes(':')) {
		const docSnap = await metricsCol.doc(metric).get();
		return docSnap.exists ? [docSnap.data()] : [];
	}

	// ── Query by metric field ────────────────────────────────────────────
	const querySnap = await metricsCol.where('metric', '==', metric).get();
	return querySnap.empty ? [] : querySnap.docs.map(d => d.data());
};