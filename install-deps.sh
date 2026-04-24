#!/bin/bash

echo "📦 Installing dependencies..."

# Backend
echo ""
echo "🔧 Installing backend packages..."
cd backend
npm install
mkdir -p logs
echo "✅ Backend packages installed"

# Frontend
echo ""
echo "🎨 Installing frontend packages..."
cd ../frontend
npm install
echo "✅ Frontend packages installed"

# Mobile (optional)
echo ""
echo "📱 Installing mobile packages..."
cd ../mobile
npm install
echo "✅ Mobile packages installed"

echo ""
echo "🎉 All packages installed successfully!"
echo ""
echo "Next steps:"
echo "1. Run migrations: psql \$DATABASE_URL -f backend/migrations/create_audit_logs.sql"
echo "2. Run migrations: psql \$DATABASE_URL -f backend/migrations/create_refunds.sql"
echo "3. Start backend: cd backend && npm run dev"
echo "4. Start frontend: cd frontend && npm start"
