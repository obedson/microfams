import React, { useEffect, useState } from 'react';
import Button from '../components/ui/Button';
import { inventoryApi, InventoryItem } from '../api/inventory';

const Inventory: React.FC = () => {
  const [items, setItems] = useState<InventoryItem[]>([]);
  const [name, setName] = useState('');
  const [unit, setUnit] = useState('');
  const [reorderLevelMinor, setReorderLevelMinor] = useState('0');
  const [message, setMessage] = useState('');
  const [movement, setMovement] = useState<Record<string, { quantity: string; reason: string }>>({});

  const load = async () => {
    const response = await inventoryApi.list();
    setItems(response.data.data);
  };
  useEffect(() => { void load(); }, []);

  const create = async (event: React.FormEvent) => {
    event.preventDefault();
    setMessage('');
    try {
      await inventoryApi.create({ name, unit, reorderLevelMinor: Number(reorderLevelMinor) });
      setName(''); setUnit(''); setReorderLevelMinor('0');
      setMessage('Inventory item created.');
      await load();
    } catch { setMessage('Unable to create inventory item.'); }
  };

  const move = async (id: string) => {
    const current = movement[id] ?? { quantity: '', reason: '' };
    try {
      await inventoryApi.move(id, { quantityMinor: Number(current.quantity), reason: current.reason, idempotencyKey: crypto.randomUUID() });
      setMovement({ ...movement, [id]: { quantity: '', reason: '' } });
      setMessage('Inventory movement recorded.');
      await load();
    } catch { setMessage('Unable to record inventory movement.'); }
  };

  return <main className="container mx-auto px-4 py-6 space-y-6">
    <header><h1 className="text-2xl font-bold">Inventory</h1><p className="text-gray-600">Track stock levels for your organization.</p></header>
    <form onSubmit={create} className="bg-white border rounded-lg p-5 space-y-4">
      <h2 className="text-lg font-semibold">Add item</h2>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <label>Name<input aria-label="Item name" required value={name} onChange={e => setName(e.target.value)} className="block w-full border rounded px-3 py-2" /></label>
        <label>Unit<input aria-label="Unit" required value={unit} onChange={e => setUnit(e.target.value)} className="block w-full border rounded px-3 py-2" /></label>
        <label>Reorder level<input aria-label="Reorder level" type="number" min="0" required value={reorderLevelMinor} onChange={e => setReorderLevelMinor(e.target.value)} className="block w-full border rounded px-3 py-2" /></label>
      </div>
      <Button type="submit">Add item</Button>
    </form>
    {message && <p role="status">{message}</p>}
    <section className="space-y-3" aria-label="Inventory items">
      {items.map(item => {
        const current = movement[item.id] ?? { quantity: '', reason: '' };
        return <article key={item.id} className="bg-white border rounded-lg p-5">
          <h2 className="font-semibold">{item.name}</h2>
          <p>{item.quantityMinor} {item.unit} in stock; reorder at {item.reorderLevelMinor}</p>
          <div className="flex gap-2 mt-3">
            <input aria-label={`Quantity for ${item.name}`} type="number" value={current.quantity} onChange={e => setMovement({ ...movement, [item.id]: { ...current, quantity: e.target.value } })} className="border rounded px-3 py-2" />
            <input aria-label={`Reason for ${item.name}`} value={current.reason} onChange={e => setMovement({ ...movement, [item.id]: { ...current, reason: e.target.value } })} className="border rounded px-3 py-2" />
            <Button type="button" onClick={() => void move(item.id)}>Record movement</Button>
          </div>
        </article>;
      })}
      {!items.length && <p>No inventory items yet.</p>}
    </section>
  </main>;
};

export default Inventory;
