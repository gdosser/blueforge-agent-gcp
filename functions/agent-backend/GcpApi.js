import { google } from 'googleapis';

export const getGcpClient = () => {
    const auth = new google.auth.GoogleAuth({
        scopes: ['https://www.googleapis.com/auth/cloud-platform']
    });
    return auth.getClient();
}

export const iam = google.iam('v1');