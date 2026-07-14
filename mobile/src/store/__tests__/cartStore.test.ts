import { useCartStore } from '../cartStore';

const maize = {
  id: 'product-1',
  name: 'Maize seed',
  price: 2500,
  quantity: 2,
  images: ['https://example.test/maize.png'],
  stock_quantity: 10,
};

describe('cart store', () => {
  beforeEach(() => {
    useCartStore.getState().clearCart();
  });

  it('adds products and calculates quantity and monetary totals', () => {
    useCartStore.getState().addItem(maize);

    expect(useCartStore.getState().items).toEqual([maize]);
    expect(useCartStore.getState().getItemCount()).toBe(2);
    expect(useCartStore.getState().getTotal()).toBe(5000);
  });

  it('combines quantities when the same product is added twice', () => {
    useCartStore.getState().addItem(maize);
    useCartStore.getState().addItem({ ...maize, quantity: 3 });

    expect(useCartStore.getState().items).toHaveLength(1);
    expect(useCartStore.getState().items[0].quantity).toBe(5);
  });

  it('updates, removes, and clears cart items deterministically', () => {
    useCartStore.getState().addItem(maize);
    useCartStore.getState().updateQuantity(maize.id, 4);

    expect(useCartStore.getState().getTotal()).toBe(10000);

    useCartStore.getState().removeItem(maize.id);
    expect(useCartStore.getState().items).toEqual([]);

    useCartStore.getState().addItem(maize);
    useCartStore.getState().clearCart();
    expect(useCartStore.getState().getItemCount()).toBe(0);
  });
});
