import fs from 'fs';import path from 'path';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-10B group document access contract',()=>{
 it('exposes a flagged, authenticated, permission-checked and rate-limited URL command',()=>{const routes=read('src/routes/groups.ts');expect(routes).toContain("requireFeature('groups.documents.download')");expect(routes).toContain("requireTenantPermission('groups.read')");expect(routes).toContain("'/:groupId/documents/versions/:versionId/download-url'");expect(routes).toContain('documentAccessLimiter');expect(routes.indexOf('router.use(resolveTenant)')).toBeLessThan(routes.indexOf("router.post('/:groupId/documents"));});
 it('registers the provider-dependent capability as fail-closed',()=>{const catalog=read('src/config/featureFlagCatalog.ts');expect(catalog).toContain("flag('groups.documents.download'");expect(catalog).toContain("approved group documents.', { risk: 'provider' })");});
 it('returns private no-store responses without exposing storage keys',()=>{const controller=read('src/controllers/groupDocumentAccessController.ts');expect(controller).toContain("setHeader('Cache-Control','no-store')");expect(controller).not.toContain('storageKey');});
});
