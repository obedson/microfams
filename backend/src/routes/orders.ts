import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { createOrder, getMyOrders, getMySales, updateOrderStatus } from '../controllers/orderController.js';

const router = Router();

router.post('/', authenticateToken, resolveTenant, createOrder);
router.get('/my-orders', authenticateToken, resolveTenant, getMyOrders);
router.get('/my-sales', authenticateToken, resolveTenant, getMySales);
router.put('/:id/status', authenticateToken, resolveTenant, updateOrderStatus);

export default router;
