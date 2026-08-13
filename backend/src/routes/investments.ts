import { Router } from 'express'; import rateLimit from 'express-rate-limit';
import { investmentProductController } from '../controllers/investmentProductController.js'; import { authenticateToken } from '../middleware/auth.js'; import { requireFeature } from '../middleware/requireFeature.js'; import { requireTenantPermission,resolveTenant } from '../middleware/tenant.js';
const router=Router(); const limiter=rateLimit({windowMs:15*60*1000,max:20,standardHeaders:true,legacyHeaders:false,message:{success:false,error:'TOO_MANY_INVESTMENT_PRODUCT_COMMANDS'}});
router.use(authenticateToken as any);router.use(resolveTenant);
router.post('/products',requireFeature('financial.investments.configure'),requireTenantPermission('financial.investments.configure'),limiter,investmentProductController.create);
router.post('/products/:productId/submit',requireFeature('financial.investments.configure'),requireTenantPermission('financial.investments.configure'),limiter,investmentProductController.submit);
router.post('/products/:productId/approve',requireFeature('financial.investments.configure'),requireTenantPermission('financial.investments.configure'),limiter,investmentProductController.approve);
export default router;
