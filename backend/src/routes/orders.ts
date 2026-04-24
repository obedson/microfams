import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { createOrder, getMyOrders, getMySales, updateOrderStatus } from '../controllers/orderController.js';

const router = Router();

router.post('/', authenticateToken, createOrder);
router.get('/my-orders', authenticateToken, getMyOrders);
router.get('/my-sales', authenticateToken, getMySales);
router.put('/:id/status', authenticateToken, updateOrderStatus);

export default router;
