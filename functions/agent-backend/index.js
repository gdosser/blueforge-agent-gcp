import express from 'express';
import https from 'https';
import { customAlphabet } from 'nanoid';
import YAML from 'yaml';
import { CloudBuildClient } from '@google-cloud/cloudbuild';
import { getApp, getAppPlan, getAppResource, putApp } from './App.js';
import { callFunction } from './Workflow.js';
import { getMetric } from './Metrics.js';
import { getCachedMetric } from './CachedMetrics.js';

const Envs = {
    DEV: 'DEV',
    PROD: 'PROD',
} 

const env = process.env.ENV || Envs.DEV;

const nanoid = customAlphabet('1234567890abcdefghijklmnopqrstuvwxyz', 5);
const CLOUD_BUILD_CONFIG_URL = 'https://raw.githubusercontent.com/googlecloudplatform/cloud-build-samples/main/examples/hello-cloudbuild/cloudbuild.yaml';
const cloudBuildClient = new CloudBuildClient();

const fetchRemoteFile = url => new Promise((resolve, reject) => {
    https.get(url, res => {
        if (!res) return reject(new Error('No response received'));
        if (res.statusCode && res.statusCode >= 400) {
            const err = new Error(`Failed to fetch ${url}`);
            err.status = res.statusCode;
            res.resume();
            return reject(err);
        }
        const chunks = [];
        res.on('data', chunk => chunks.push(chunk));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    }).on('error', reject);
});

const app = express();

// Logging middleware
if (env == Envs.DEV) {

}

app.use((req, res, next) => {
    req.id = nanoid();
    console.log('REQUEST', req.id, req.method, req.url, JSON.stringify(req.body));
    next();
});

/**
 * 
 * @param {*} res 
 * @param {*} status 
 * @param {*} json 
 */
const sendResult = (req, res, status, json) => {
    if (env == Envs.DEV && json) console.log('RESPONSE', req.id, JSON.stringify(json));
    res.status(status).json(json);
}

// API accessible by the master server


/**
 * 
 */
app.get('', (req, res, next) => {
    const appId = `${req.params.organization}/${req.params.appName}`;
    return getApp(appId)
        .then(result => sendResult(req, res, 200, result))
        .catch(err => next(err));
});

/**
 * 
 */
app.post('/update', async (req, res, next) => {
    const projectId = process.env.PROJECT_ID;
    if (!projectId) {
        return next(new Error('PROJECT_ID environment variable is required'));
    }

    try {
        const [configContent] = await Promise.all([
            fetchRemoteFile(CLOUD_BUILD_CONFIG_URL),
        ]);

        const buildConfig = YAML.parse(configContent) || {};
        buildConfig.substitutions = {
            ...(buildConfig.substitutions || {}),
            _MESSAGE: 'Hello from CLI',
            _COLOR: 'blue',
        };

        const [operation] = await cloudBuildClient.createBuild({ projectId, build: buildConfig });
        const [build] = await operation.promise();

        return sendResult(req, res, 200, build);
    } catch (err) {
        return next(err);
    }
});

/**
 * deploy a new or update an app.
 */
app.put('/apps/:organization/:appName', (req, res, next) => {
    const appId = `${req.params.organization}/${req.params.appName}`;
    const { deploymentId, architecture, artifacts, masterActions } = req.body;
    return putApp(appId, deploymentId, architecture, artifacts, masterActions)
        .then(result => sendResult(req, res, 201, result))
        .catch(err => next(err));
});

/**
 * 
 */
app.get('/apps/:organization/:appName', (req, res, next) => {
    const appId = `${req.params.organization}/${req.params.appName}`;
    return getApp(appId)
        .then(result => sendResult(req, res, 200, result))
        .catch(err => next(err));
});

/**
 * 
 */
app.get('/apps/:organization/:appName/resources/:resourceId', (req, res, next) => { // TODO REMOVE ?????
    const appId = `${req.params.organization}/${req.params.appName}`;
    return getAppResource(appId, decodeURIComponent(req.params.resourceId))
        .then(result => sendResult(req, res, 200, result))
        .catch(err => next(err));
});

/**
 *
 */
app.get('/apps/:organization/:appName/resources/:resourceId/metrics/:metric', (req, res, next) => {
    const appId = `${req.params.organization}/${req.params.appName}`;
    return getCachedMetric(appId, decodeURIComponent(req.params.resourceId), req.params.metric)
        .then(result => sendResult(req, res, 200, result))
        .catch(err => next(err));
});

/**
 * 
 */
app.post('/apps/:organization/:appName/services/:serviceId/metrics/:metric', (req, res, next) => {
    const appId = `${req.params.organization}/${req.params.appName}`;
    return getMetric(appId, req.params.serviceId, req.params.metric, req.body)
        .then(result => sendResult(req, res, 200, result))
        .catch(err => next(err));
});

/**
 * 
 */
app.get('/apps/:organization/:appName/plans/:planId', (req, res, next) => {
    const appId = `${req.params.organization}/${req.params.appName}`;
    return getAppPlan(appId, req.params.planId)
        .then(result => sendResult(req, res, 200, result))
        .catch(err => next(err));
});

// Workflow functions helpers - used internally
app.post('/workflow/:functionName', (req, res, next) => {
    return callFunction(req.params.functionName, req.body)
        .then(result => sendResult(req, res, 201, result))
        .catch(err => next(err));
});

// Handling 404
app.use((req, res) => {
    res.sendStatus(404);
});

// Handling other errors
app.use((err, req, res, next) => {
    // only display non handled errors
    if (!err.type) console.log(err);
    // create the json response
    var json = {};
    if (err.name) json.name = err.name;
    if (err.message) json.message = err.message;
    // Display the cause only in dev
    if (env == Envs.DEV) {
        if (err.cause) json.cause = err.cause;
        if (err.stack) json.stack = err.stack;
    }
    res.status(err.type || 500).json(json);
});

export const handle = app;
