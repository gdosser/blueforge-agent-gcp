import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const AGENT_DATABASE_NAME = process.env.AGENT_DATABASE_NAME;

console.log(`Connecting to database ${AGENT_DATABASE_NAME}.`);

const firebaseApp = initializeApp();
export const db = getFirestore(firebaseApp, AGENT_DATABASE_NAME);

export { FieldPath, FieldValue, Timestamp } from 'firebase-admin/firestore'; 