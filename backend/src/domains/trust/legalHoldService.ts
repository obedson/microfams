import crypto from 'node:crypto';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
import { TrustDomainError } from './trustRules.js';
import { LegalHoldFeatureGate,LegalHoldFilter,LegalHoldRepository,PlaceLegalHoldInput,ReleaseLegalHoldInput } from './legalHoldTypes.js';
import { SupabaseLegalHoldRepository } from './supabaseLegalHoldRepository.js';
const code=/^[A-Z][A-Z0-9_]{2,63}$/;const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const hash=(v:object)=>crypto.createHash('sha256').update(JSON.stringify(v)).digest('hex');
const key=(v:string)=>{const x=v.trim();if(x.length<8||x.length>160)throw new TrustDomainError('IDEMPOTENCY_KEY_REQUIRED',400);return x;};
const reason=(v:string)=>{const x=v.trim().toUpperCase();if(!code.test(x))throw new TrustDomainError('INVALID_REASON_CODE',400);return x;};
const note=(v?:string)=>{const x=v?.trim();if(x&&x.length>1000)throw new TrustDomainError('INVALID_LEGAL_HOLD_NOTE',400);return x||undefined;};
const identifier=(v:string,type:string)=>{const x=v.trim();if(!x||x.length>256||(type!=='data_class'&&!uuid.test(x)))throw new TrustDomainError('INVALID_LEGAL_HOLD_SUBJECT',400);return x;};
export class FeatureFlagLegalHoldGate implements LegalHoldFeatureGate {constructor(private flags:FeatureFlagService){}async assertPlacementEnabled(c:{actorId:string;environment?:'development'|'test'|'staging'|'production'}){const d=await this.flags.evaluate('trust.legal_holds',{actorId:c.actorId,environment:c.environment??'development'});if(!d.enabled)throw new TrustDomainError('TRUST_FEATURE_DISABLED',403);}}
export class LegalHoldService {constructor(private repository:LegalHoldRepository,private gate:LegalHoldFeatureGate){}
 list(filter:LegalHoldFilter={}){return this.repository.list({...filter,limit:Math.min(100,Math.max(1,filter.limit??50))});}
 async place(actorId:string,raw:PlaceLegalHoldInput,environment?:'development'|'test'|'staging'|'production'){await this.gate.assertPlacementEnabled({actorId,environment});const input={...raw,organizationId:raw.organizationId?identifier(raw.organizationId,'organization'):undefined,subjectId:identifier(raw.subjectId,raw.subjectType),reasonCode:reason(raw.reasonCode),note:note(raw.note),idempotencyKey:key(raw.idempotencyKey)};try{return await this.repository.place(actorId,input,hash(input));}catch(e){if(e instanceof TrustDomainError)throw e;throw new TrustDomainError('LEGAL_HOLD_COMMAND_FAILED',409);}}
 async release(actorId:string,raw:ReleaseLegalHoldInput){const input={...raw,holdId:identifier(raw.holdId,'hold'),reasonCode:reason(raw.reasonCode),note:note(raw.note),idempotencyKey:key(raw.idempotencyKey)};try{return await this.repository.release(actorId,input,hash(input));}catch(e){if(e instanceof TrustDomainError)throw e;throw new TrustDomainError('LEGAL_HOLD_COMMAND_FAILED',409);}}
}
export const legalHoldService=new LegalHoldService(new SupabaseLegalHoldRepository(),new FeatureFlagLegalHoldGate(new FeatureFlagService(new SupabaseFeatureFlagRepository())));