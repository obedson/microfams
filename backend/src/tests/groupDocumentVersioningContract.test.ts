import fs from 'fs';
import path from 'path';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-10A group document versioning',()=>{
 const migration=read('migrations/install_group_documents_foundation.sql');
 it('keeps document metadata and ownership tenant scoped',()=>{expect(migration).toContain("position(o::TEXT||'/'||g::TEXT||'/' IN storage)<>1");expect(migration).toContain('GROUP_DOCUMENT_OWNER_INVALID');expect(migration).toContain('checksum_sha256');expect(migration).toContain('access_policy');expect(migration).toContain('legal_hold_status');});
 it('publishes through an approved independent governance decision',()=>{expect(migration).toContain("q.proposal_type<>'document_publication'");expect(migration).toContain('a=v.created_by');expect(migration).toContain('a=q.proposer_id');});
 it('makes approved versions and document events immutable',()=>{expect(migration).toContain('GROUP_DOCUMENT_APPROVED_VERSION_IMMUTABLE');expect(migration).toContain('GROUP_DOCUMENT_EVIDENCE_IMMUTABLE');expect(migration).toContain('correction_of_version_id');});
});
