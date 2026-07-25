export type LegalHoldSubjectType='user'|'organization'|'membership'|'case'|'data_class';
export type LegalHoldStatus='active'|'released';
export interface LegalHold { id:string; organizationId:string|null; subjectType:LegalHoldSubjectType; subjectId:string; reasonCode:string; status:LegalHoldStatus; placedAt:string; releasedAt:string|null; }
export interface PlaceLegalHoldInput { organizationId?:string; subjectType:LegalHoldSubjectType; subjectId:string; reasonCode:string; note?:string; idempotencyKey:string; }
export interface ReleaseLegalHoldInput { holdId:string; reasonCode:string; note?:string; idempotencyKey:string; }
export interface LegalHoldFilter { organizationId?:string; status?:LegalHoldStatus; subjectType?:LegalHoldSubjectType; limit?:number; }
export interface LegalHoldRepository { list(filter:LegalHoldFilter):Promise<LegalHold[]>; place(actorId:string,input:PlaceLegalHoldInput,requestHash:string):Promise<unknown>; release(actorId:string,input:ReleaseLegalHoldInput,requestHash:string):Promise<unknown>; }
export interface LegalHoldFeatureGate { assertPlacementEnabled(context:{actorId:string;environment?:'development'|'test'|'staging'|'production'}):Promise<void>; }