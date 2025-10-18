import deepEqual from 'fast-deep-equal';

const ActionTypes = {
    IDS: 'ids',
    ACCOUNTS: 'accounts',
    SERVICES: 'services',
    LAYERS: 'layers',
    RESOURCES: 'resources',
}

const Actions = {
    CREATE: 'create',
    UPDATE: 'update',
    DELETE: 'delete',
}

/**
 * Compute differences between two objects by comparing their keys and values.
 *
 * The result groups changes into three categories:
 *  - '+' : keys that exist only in `next` (added)
 *  - '-' : keys that exist only in `prev` (removed)
 *  - '~' : keys present in both, but whose values differ (updated)
 *
 * @param {Record<string, any>} prev - The previous object state.
 * @param {Record<string, any>} next - The next object state.
 * @returns {{ '+': string[], '-': string[], '~': string[] }}
 *          An object describing which keys were added, removed, or updated.
 */
const getDiffObj = (prev, next) => {
    const kprev = Object.keys(prev);
    const knext = Object.keys(next);
    const addedFields = knext.filter(k => !kprev.includes(k));
    const removedFields = kprev.filter(k => !knext.includes(k));
    const commonFields = knext.filter(k => kprev.includes(k));
    const updatedFields = commonFields.filter(k => !deepEqual(prev[k], next[k]));
    return {
        '+': addedFields,
        '-': removedFields,
        '~': updatedFields,
    };
};

/**
 * Compute differences between two arrays of primitive values (strings, numbers, etc.).
 *
 * The result groups changes into two categories:
 *  - '+' : values present in `next` but not in `prev` (added)
 *  - '-' : values present in `prev` but not in `next` (removed)
 *
 * @param {Array<string>} prev - The previous array.
 * @param {Array<string>} next - The next array.
 * @returns {{ '+': string[], '-': string[] }}
 *          An object describing which values were added or removed.
 */
const getDiffArr = (prev, next) => {
    const addedFields = next.filter(k => !prev.includes(k));
    const removedFields = prev.filter(k => !next.includes(k));
    return {
        '+': addedFields,
        '-': removedFields,
    };
};

/**
 * Compute differences between the current architecture `state` and the `target` one.
 * The function compares multiple aspects: ids, accounts, services, layers, and resources.
 *
 * @param {Object} state - The current architecture state.
 * @param {Object} target - The target architecture state to compare against.
 * @returns {Object} Differences between `state` and `target`.
 *                   - diffIds {Array<string>} - Missing or extra IDs.
 *                   - diffAccounts {Array<string>} - Differences in account-related IDs.
 *                   - diffServices {Object} - Differences in services definitions.
 *                   - diffLayers {Object} - Differences in layer definitions.
 *                   - diffResources {Object} - Differences in resource definitions.
 */
const getDiffs = (state, target) => {
    if (!state || !target) {
        throw new Error("Both `state` and `target` must be provided.");
    }

    // Extract all resource IDs from the target
    const targetResourceIds = Object.keys(target.resources || {});

    // Derive module IDs from resource IDs (everything before the last "/")
    const targetModuleIds = [
        ...new Set(
            targetResourceIds.map(resourceId => {
                const index = resourceId.lastIndexOf('/');
                return index === -1 ? '/' : resourceId.slice(0, index + 1);
            })
        )
    ];

    // Combine resource and module IDs for global comparison
    const targetResourceAndModuleIds = [...targetModuleIds, ...targetResourceIds];

    // Compute differences for each category
    const diffIds = getDiffArr(Object.keys(state.ids || {}), targetResourceAndModuleIds);
    const diffAccounts = getDiffArr(Object.keys(state.accounts || {}), targetResourceAndModuleIds);
    const diffServices = getDiffObj(state.services || {}, target.services || {});
    const diffLayers = getDiffObj(state.layers || {}, target.layers || {});
    const diffResources = getDiffObj(state.resources || {}, target.resources || {});

    return { diffIds, diffAccounts, diffServices, diffLayers, diffResources };
};

/**
 * Expand the list of resources to update by including transitive dependents.
 *
 * Starting from the resources marked as added/changed, the function:
 * 1. Seeds a set with them.
 * 2. Builds a reverse dependency graph (depId -> [resources that depend on it]).
 * 3. Traverses this graph to collect all resources indirectly affected.
 * 
 * @param {Object} target - The target architecture state.
 * @param {Object} diffResources - Object with '+' and '~' arrays of resourceIds.
 * @returns {string[]} A complete list of resourceIds that must be created/updated.
 */
const expandResourceUpdates = (target, diffResources) => {
    const toHandle = new Set();

    // 1. Seed set with known additions/updates
    for (const id of diffResources['+']) toHandle.add(id);
    for (const id of diffResources['~']) toHandle.add(id);

    // 2. Build reverse dependency graph (depId -> dependents)
    const dependents = new Map();
    const resources = target?.resources || {};
    for (const resourceId in resources) {
        const deps = resources[resourceId].dependencies || {};
        for (const key in deps) {
            const dep = deps[key];
            if (dep?.output && dep.resourceId) {
                if (!dependents.has(dep.resourceId)) dependents.set(dep.resourceId, []);
                dependents.get(dep.resourceId).push(resourceId);
            }
        }
    }

    // 3. Traverse transitive dependents
    const stack = Array.from(toHandle);
    while (stack.length) {
        const current = stack.pop();
        const children = dependents.get(current);
        if (!children) continue;
        for (const child of children) {
            if (!toHandle.has(child)) {
                toHandle.add(child);
                stack.push(child);
            }
        }
    }

    return Array.from(toHandle);
};

/**
 * Build a direct dependency index:
 * For each resourceId, list the unique resourceIds it depends on.
 *
 * @param {Object} target
 * @returns {Record<string, string[]>} resourceId -> array of dependency resourceIds
 */
const buildDependenciesIndex = (target) => {
    const resources = (target && target.resources) || {};
    const index = {};

    for (const resourceId in resources) {
        const res = resources[resourceId];
        const deps = (res && res.dependencies) || {};
        const list = [];

        // Collect unique dependency resourceIds (arrays only, no Set)
        for (const key in deps) {
            const dep = deps[key];
            const depId = dep && dep.resourceId;
            if (!depId) continue;
            if (!list.includes(depId)) list.push(depId);
        }

        index[resourceId] = list;
    }

    return index;
};

/**
 * Build a reverse dependency index: for each dependency resourceId, list the resources that depend on it.
 *
 * @param {Object} state
 * @returns {Record<string, string[]>} Map: depResourceId -> array of dependent resourceIds
 */
const buildDependentsIndex = state => {
    const resources = state && state.resources ? state.resources : {};
    const index = {};

    for (const resourceId in resources) {
        const res = resources[resourceId];
        if (!res) continue;

        const deps = res.dependencies;
        if (!deps) continue;

        for (const key in deps) {
            const dep = deps[key];
            if (!dep || !dep.resourceId) continue;

            const depId = dep.resourceId;
            if (!index.hasOwnProperty(depId)) index[depId] = [];
            if (!index[depId].includes(resourceId)) index[depId].push(resourceId);
        }
    }
    return index;
}

/**
 * A resource is ready to deploy or destroy if none of its dependencies are still pending.
 * 
 * For create or update: use dependency index
 * (A -> B) B must be deployed before A.
 * 
 * For delete: use reverse dependency index
 * (A -> B) A must be destroyed before B.
 *
 * @param {string} resourceId
 * @param {Object} index
 * @param {string[]} resourceUpdates - resourceIds still waiting to be deployed / destroy
 * @returns {boolean}
 */
const isReady = (resourceId, index, resourceUpdates) => {
    const deps = index[resourceId];
    if (!deps) return true;
    // If any dependency is still pending, resource is not ready
    const hasPendingDep = deps.some(depId => depId && resourceUpdates.includes(depId));
    return !hasPendingDep;
};

/**
 * Build deployment waves for resources, ensuring dependencies are respected.
 *
 * This function groups resources scheduled for creation or update into ordered "waves".
 * Each wave contains resources that can be safely deployed in parallel, i.e.
 * none of them depend on any resource still pending deployment.
 *
 * Algorithm:
 * 1. Build the dependency index (which resources depend on which others).
 * 2. Expand the list of resources to include all transitive dependents.
 * 3. Iteratively collect resources whose dependencies are already satisfied.
 * 4. Remove them from the pending list and record them as a "wave".
 * 5. Repeat until all resources are scheduled or a cycle is detected.
 *
 * Throws an error if the maximum number of passes is reached and some resources
 * remain undeployed (indicating a dependency cycle).
 *
 * @param {Object} target - Target architecture containing resources and their dependencies.
 * @param {{ '+': string[], '~': string[] }} diffResources - Object containing resourceIds
 *   to create (`'+'`) or update (`'~'`).
 * @returns {string[][]} Array of waves (arrays of resourceIds), in order of safe deployment.
 *
 * @throws {Error} If a dependency cycle prevents complete deployment of resources.
 */
const buildResourceDeployWaves = (target, diffResources) => {
    // 0) Create the dependency index
    const index = buildDependenciesIndex(target);

    // 1) Expand to include transitive dependents
    let resourceUpdates = expandResourceUpdates(target, diffResources);

    const waves = []; // array of arrays (deployment order by passes)
    const initialCount = resourceUpdates.length;

    for (let pass = 0; pass < initialCount && resourceUpdates.length; pass++) {
        // 2) Collect all resources that are ready in this pass
        const readyNow = resourceUpdates.filter(id => 
            isReady(id, index, resourceUpdates)
        );

        if (readyNow.length) {
            // 3) Record this deployment wave
            waves.push(readyNow);

            // 4) Remove processed from the pending list
            resourceUpdates = resourceUpdates.filter(id => !readyNow.includes(id));
        }
        // else: no progress this pass; we let the max-pass cap handle deadlock at the end
    }

    // 5) Deadlock if something remains after max passes
    if (resourceUpdates.length) {
        throw new Error(
            `Max passes reached (${initialCount}) with ${resourceDeletes.length} resources still awaiting creation or update. Possible dependency cycle.`
        );
    }

    return waves;
}

/**
 * Build destruction waves for resources, ensuring dependencies are respected.
 *
 * This function groups resources scheduled for deletion into ordered "waves".
 * Each wave contains resources that can be safely deleted in parallel, i.e.
 * none of them are required by any other resource still pending deletion.
 *
 * Algorithm:
 * 1. Build the reverse dependency index (who depends on whom).
 * 2. Iteratively collect resources with no remaining dependents in the pending set.
 * 3. Remove them from the pending list and record them as a "wave".
 * 4. Repeat until all resources are scheduled or a cycle is detected.
 *
 * Throws an error if the maximum number of passes is reached and some resources
 * remain undeleted (indicating a dependency cycle).
 *
 * @param {Object} state - Current architecture state containing resources and their dependencies.
 * @param {{ '-': string[] }} diffResources - Object with at least a `'-'` array listing resourceIds to delete.
 * @returns {string[][]} Array of waves (arrays of resourceIds), in order of safe deletion.
 *
 * @throws {Error} If a dependency cycle prevents complete deletion of resources.
 */
const buildResourceDestroyWaves = (state, diffResources) => {
    // 0) Create the dependent index
    const index = buildDependentsIndex(state);

    let resourceDeletes = diffResources['-'];

    const waves = []; // array of arrays (deployment order by passes)
    const initialCount = resourceDeletes.length;

    for (let pass = 0; pass < initialCount && resourceDeletes.length; pass++) {
        // 2) Collect all resources that are ready in this pass
        const readyNow = resourceDeletes.filter(id =>
            isReady(id, index, resourceDeletes)
        );

        if (readyNow.length) {
            // 3) Record this deployment wave
            waves.push(readyNow);

            // 4) Remove processed from the pending list
            resourceDeletes = resourceDeletes.filter(id => !readyNow.includes(id));
        }
        // else: no progress this pass; we let the max-pass cap handle deadlock at the end
    }

    // 5) Deadlock if something remains after max passes
    if (resourceDeletes.length) {
        throw new Error(
            `Max passes reached (${initialCount}) with ${resourceDeletes.length} resources still pending deletion. Possible dependency cycle.`
        );
    }

    return waves;
}

/**
 * Build a full, ordered plan of steps grouped by waves (parallelizable batches).
 * Each item in `steps` is a "wave" (array of step objects) that can run in parallel.
 * Single-step waves are used when sequencing is required.
 *
 * Waves order (high level):
 *   1) Create/Update services (parallel)
 *   2) Create/Update layers  (parallel)
 *   3) Create IDs            (sequential, one per wave)
 *   4) Create accounts       (sequential, one per wave)
 *   5) Create/Update resources (waves computed from dependency graph)
 *   6) Delete resources        (waves computed from reverse dependency graph)
 *   7) Delete accounts       (parallel)
 *   8) Delete IDs            (parallel)
 *   9) Delete layers         (parallel)
 *  10) Delete services       (parallel)
 *
 * @param {Object} state  - Current architecture (before changes)
 * @param {Object} target - Target architecture (after changes)
 * @returns {Array<Array<Object>>} steps - waves of formatted step objects
 */
export const getSteps = (state, target) => {
    const { diffIds, diffAccounts, diffServices, diffLayers, diffResources } = getDiffs(state, target);

    // Step ID generator
    const nextStepId = (() => { let i = 0; return () => `step_${i++}`; })();

    const steps = [];

    // Helpers to push waves
    const pushParallel = (ids, mapToStep) => {
        if (!ids.length) return;
        steps.push(ids.map(mapToStep));
    };
    const pushSequential = (ids, mapToStep) => {
        for (let i = 0; i < ids.length; i++) steps.push([mapToStep(ids[i])]);
    };

    // 1) SERVICES (create/update parallel)gcloud storage buckets describe BUCKET_NAME --format="value(website.mainPageSuffix)"
    pushParallel(
        [...diffServices['+'], ...diffServices['~']],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.SERVICES,
            action: diffServices['+'].includes(id) ? Actions.CREATE : Actions.UPDATE,
            id,
            data: target.services[id],
        })
    );

    // 2) LAYERS (create/update parallel)
    pushParallel(
        [...diffLayers['+'], ...diffLayers['~']],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.LAYERS,
            action: diffLayers['+'].includes(id) ? Actions.CREATE : Actions.UPDATE,
            id,
            data: target.layers[id],
        })
    );

    // 3) IDS (create sequential)
    pushSequential(
        diffIds['+'],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.IDS,
            action: Actions.CREATE,
            id,
            data: {},
        })
    );

    // 4) ACCOUNTS (create sequential)
    pushSequential(
        diffAccounts['+'],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.ACCOUNTS,
            action: Actions.CREATE,
            id,
            data: { service: target.resources[id]?.service || null },
        })
    );

    // 5) RESOURCES (deploy waves)
    {
        const waves = buildResourceDeployWaves(target, diffResources);
        waves.forEach(resourceIds => {
            steps.push(
                resourceIds.map(id => ({
                    stepId: nextStepId(),
                    type: ActionTypes.RESOURCES,
                    action: diffResources['+'].includes(id) ? Actions.CREATE : Actions.UPDATE,
                    id,
                    data: target.resources[id],
                }))
            );
        });
    }

    // 6) RESOURCES (destroy waves)
    {
        const waves = buildResourceDestroyWaves(state, diffResources);
        waves.forEach(resourceIds => {
            steps.push(
                resourceIds.map(id => ({
                    stepId: nextStepId(),
                    type: ActionTypes.RESOURCES,
                    action: Actions.DELETE,
                    id,
                    data: state.resources[id],
                }))
            );
        });
    }

    // 7) ACCOUNTS (delete parallel)
    pushParallel(
        diffAccounts['-'],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.ACCOUNTS,
            action: Actions.DELETE,
            id,
            data: { service: state.resources[id]?.service || null },
        })
    );

    // 8) IDS (delete parallel)
    pushParallel(
        diffIds['-'],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.IDS,
            action: Actions.DELETE,
            id,
            data: {},
        })
    );

    // 9) LAYERS (delete parallel)
    pushParallel(
        diffLayers['-'],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.LAYERS,
            action: Actions.DELETE,
            id,
            data: state.layers[id],
        })
    );

    // 10) SERVICES (delete parallel)
    pushParallel(
        diffServices['-'],
        id => ({
            stepId: nextStepId(),
            type: ActionTypes.SERVICES,
            action: Actions.DELETE,
            id,
            data: state.services[id],
        })
    );

    console.log('🟩 steps', JSON.stringify(steps));

    return steps;
};