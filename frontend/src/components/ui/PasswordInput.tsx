import React, { useState, forwardRef } from 'react';
import { Eye, EyeOff } from 'lucide-react';

interface PasswordInputProps {
  placeholder?: string;
  className?: string;
  error?: boolean;
  name?: string;
  required?: boolean;
}

const PasswordInput = forwardRef<HTMLInputElement, PasswordInputProps>(({
  placeholder = "Enter password",
  className = "",
  error = false,
  name,
  required = false,
  ...props
}, ref) => {
  const [showPassword, setShowPassword] = useState(false);

  return (
    <div className="relative">
      <input
        ref={ref}
        type={showPassword ? "text" : "password"}
        placeholder={placeholder}
        name={name}
        required={required}
        className={`w-full pr-12 pl-4 py-3 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent transition-colors ${
          error ? 'border-red-300' : 'border-gray-300'
        } ${className}`}
        {...props}
      />
      <button
        type="button"
        onClick={() => setShowPassword(!showPassword)}
        className="absolute right-3 top-1/2 transform -translate-y-1/2 text-gray-400 hover:text-gray-600 transition-colors"
      >
        {showPassword ? <EyeOff size={20} /> : <Eye size={20} />}
      </button>
    </div>
  );
});

PasswordInput.displayName = 'PasswordInput';

export default PasswordInput;
