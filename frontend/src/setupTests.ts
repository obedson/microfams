import '@testing-library/jest-dom';
import { TextDecoder, TextEncoder } from 'util';

// React Router 7 targets modern runtimes. Jest's jsdom environment in
// react-scripts 5 does not install these standard encoding globals.
Object.assign(globalThis, {
  TextDecoder,
  TextEncoder,
});
