import { GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { randomUUID } from 'crypto';
import s3Client from '../../config/s3.js';
import { supabase } from '../../utils/supabase.js';

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EXPIRES_IN_SECONDS=300;
export interface GroupDocumentAccessCommand { organizationId:string; groupId:string; actorId:string; versionId:string; }
export interface GroupDocumentAccessMetadata { storageKey:string; filename:string; mediaType:string; expiresAt:string; }
export interface GroupDocumentAccessGateway { authorize(command:GroupDocumentAccessCommand&{correlationId:string;expiresAt:string;atTime:string}):Promise<GroupDocumentAccessMetadata>; }
export interface GroupDocumentSigner { sign(input:{storageKey:string;filename:string;expiresInSeconds:number}):Promise<string>; }
export class GroupDocumentAccessError extends Error { constructor(public readonly code:string,public readonly status:number){super(code);this.name='GroupDocumentAccessError';} }
export class SupabaseGroupDocumentAccessGateway implements GroupDocumentAccessGateway {
 async authorize(c:GroupDocumentAccessCommand&{correlationId:string;expiresAt:string;atTime:string}){const {data,error}=await supabase.rpc('authorize_group_document_download',{p_organization:c.organizationId,p_group:c.groupId,p_actor:c.actorId,p_version:c.versionId,p_correlation:c.correlationId,p_expires_at:c.expiresAt,p_at_time:c.atTime});if(error||!data){const message=error?.message??'';if(message.includes('GROUP_DOCUMENT_ACCESS_DENIED'))throw new GroupDocumentAccessError('GROUP_DOCUMENT_ACCESS_DENIED',403);if(message.includes('GROUP_DOCUMENT_VERSION_NOT_FOUND'))throw new GroupDocumentAccessError('GROUP_DOCUMENT_VERSION_NOT_FOUND',404);throw new GroupDocumentAccessError('GROUP_DOCUMENT_ACCESS_UNAVAILABLE',503);}const row=data as Record<string,unknown>;return{storageKey:String(row.storage_key),filename:String(row.filename),mediaType:String(row.media_type),expiresAt:String(row.expires_at)};}
}
export class S3GroupDocumentSigner implements GroupDocumentSigner {
 async sign(input:{storageKey:string;filename:string;expiresInSeconds:number}){const bucket=process.env.AWS_S3_BUCKET;if(!bucket)throw new GroupDocumentAccessError('GROUP_DOCUMENT_STORAGE_UNAVAILABLE',503);const filename=input.filename.replace(/[^A-Za-z0-9._-]/g,'_');try{return await getSignedUrl(s3Client,new GetObjectCommand({Bucket:bucket,Key:input.storageKey,ResponseContentDisposition:`attachment; filename="${filename}"`}),{expiresIn:input.expiresInSeconds});}catch{throw new GroupDocumentAccessError('GROUP_DOCUMENT_STORAGE_UNAVAILABLE',503);}}
}
export class GroupDocumentAccessService {
 constructor(private readonly gateway:GroupDocumentAccessGateway=new SupabaseGroupDocumentAccessGateway(),private readonly signer:GroupDocumentSigner=new S3GroupDocumentSigner()){}
 async issue(c:GroupDocumentAccessCommand){if(![c.organizationId,c.groupId,c.actorId,c.versionId].every(v=>UUID.test(v)))throw new GroupDocumentAccessError('GROUP_DOCUMENT_ACCESS_COMMAND_INVALID',400);const now=new Date();const expiresAt=new Date(now.getTime()+EXPIRES_IN_SECONDS*1000).toISOString();const metadata=await this.gateway.authorize({...c,correlationId:randomUUID(),expiresAt,atTime:now.toISOString()});const url=await this.signer.sign({storageKey:metadata.storageKey,filename:metadata.filename,expiresInSeconds:EXPIRES_IN_SECONDS});return{url,filename:metadata.filename,mediaType:metadata.mediaType,expiresAt:metadata.expiresAt};}
}
export const groupDocumentAccessService=new GroupDocumentAccessService();
