#!/bin/bash

echo "🧪 Testing Full-Stack Communication System"
echo "=========================================="

# Test 1: Backend API Tests
echo "1️⃣ Running Backend API Tests..."
cd backend
npm test -- --testPathPattern="communication-backend" --watchAll=false --silent
if [ $? -eq 0 ]; then
    echo "✅ Backend API tests passed"
else
    echo "❌ Backend API tests failed"
    exit 1
fi

# Test 2: Frontend Component Tests  
echo "2️⃣ Running Frontend Component Tests..."
cd ../frontend
npm test -- --testPathPattern="MessageButton.properties|InAppMessaging.properties|ContactInformation.properties" --watchAll=false --silent
if [ $? -eq 0 ]; then
    echo "✅ Frontend component tests passed"
else
    echo "❌ Frontend component tests failed"
    exit 1
fi

# Test 3: Check if servers can start
echo "3️⃣ Testing Server Startup..."
cd ../backend
timeout 10s npm run dev > /dev/null 2>&1 &
BACKEND_PID=$!
sleep 5

if kill -0 $BACKEND_PID 2>/dev/null; then
    echo "✅ Backend server starts successfully"
    kill $BACKEND_PID
else
    echo "❌ Backend server failed to start"
    exit 1
fi

echo ""
echo "🎉 All tests passed! Communication system is ready."
echo ""
echo "To test manually:"
echo "1. cd backend && npm run dev"
echo "2. cd frontend && npm start"
echo "3. Login and test messaging between farmer and owner"
