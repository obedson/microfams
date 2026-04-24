import toast, { Toaster } from 'react-hot-toast';

export const showSuccess = (message: string) => {
  toast.success(message, {
    duration: 4000,
    position: 'top-right',
  });
};

export const showError = (message: string) => {
  toast.error(message, {
    duration: 5000,
    position: 'top-right',
  });
};

export const showLoading = (message: string) => {
  return toast.loading(message, {
    position: 'top-right',
  });
};

export const dismissToast = (toastId: string) => {
  toast.dismiss(toastId);
};

export { Toaster };
