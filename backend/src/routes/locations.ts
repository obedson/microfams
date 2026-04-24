import { Router } from 'express';
import { LocationModel } from '../models/Location.js';

const router = Router();

router.get('/states', async (req, res) => {
  const states = await LocationModel.getAllStates();
  res.json(states);
});

router.get('/lgas/:stateId', async (req, res) => {
  const lgas = await LocationModel.getLGAsByState(parseInt(req.params.stateId));
  res.json(lgas);
});

export default router;
