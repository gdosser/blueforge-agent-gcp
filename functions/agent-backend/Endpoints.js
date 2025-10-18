import { UrlMapsClient, NetworkEndpointGroupsClient, RegionNetworkEndpointGroupsClient, BackendBucketsClient, BackendServicesClient } from '@google-cloud/compute';
import { customAlphabet } from 'nanoid';
import { v4 as uuid } from 'uuid';
import { db } from './Firebase.js';

const PROJECT_ID = process.env.PROJECT_ID;

const URL_MAP_NAME = 'http-lb';

const urlMapsClient = new UrlMapsClient();

const regionNetworkEndpointGroupsClient = new RegionNetworkEndpointGroupsClient();
const networkEndpointGroupsClient = new NetworkEndpointGroupsClient();
const backendServicesClient = new BackendServicesClient();
const backendBucketClient = new BackendBucketsClient();

/*
cloudRun:
  service: dashboard-backend
creationTimestamp: '2022-02-02T03:28:16.513-08:00'
id: '7626142503763694655'
kind: compute#networkEndpointGroup
name: dashboard-backend-neg
networkEndpointType: SERVERLESS
region: https://www.googleapis.com/compute/v1/projects/blueforge-322008/regions/europe-west2
selfLink: https://www.googleapis.com/compute/v1/projects/blueforge-322008/regions/europe-west2/networkEndpointGroups/dashboard-backend-neg
size: 0
*/

 
const createNetworkEndpointGroups = (name, service) => {
    return regionNetworkEndpointGroupsClient.get({
        project: PROJECT_ID,
        requestId: '',
        networkEndpointGroupResource: {
            name: '',
            description: '',
            networkEndpointType: 'SERVERLESS',
            cloudRun: {
                service: '',
            }
        }
    });
}

const deleteNetworkEndpointGroups = name => {
    return globalNetworkEndpointGroupsClient.delete({
        project: PROJECT_ID,
        requestId: '',
        networkEndpointGroup: name
    });
}

const createBackendService = () => {
    return backendServicesClient.get({
        project: PROJECT_ID,
        requestId: '',
        backendServiceResource: {

        }
    })
}

const deleteBackendService = name => {
    return backendServicesClient.delete({
        project: PROJECT_ID,
        requestId: '',
        backendService: name
    })
}

const createBackendBucket = () => {
    return backendBucketClient.insert({
        project: PROJECT_ID,
        requestId: '',
        backendBucketResource: {

        }
    })
}

const deleteBackendBucket = name => {
    return backendBucketClient.delete({
        project: PROJECT_ID,
        requestId: '',
        backendBucket: name
    })
}



export const addEndpoints = (endpoints, urls) => {

    // create NEG and backends

    // set the urlmap

    // remove NEG and backends

}

