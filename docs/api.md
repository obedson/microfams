# API Documentation

## Overview

The Agro-FinTech Credit System provides a comprehensive REST API for managing agricultural education, group collaboration, and collective project financing. All endpoints require authentication unless otherwise specified.

## Base URL
```
Production: https://api.farmle.com/v1
Development: http://localhost:3000/api/v1
```

## Authentication

All authenticated endpoints require a Bearer token in the Authorization header:
```
Authorization: Bearer <jwt_token>
```

## Response Format

All API responses follow this standard format:
```json
{
  "success": boolean,
  "data": object | array,
  "message": string,
  "timestamp": "ISO 8601 string",
  "requestId": "uuid"
}
```

Error responses include additional fields:
```json
{
  "success": false,
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable message",
    "details": object
  },
  "timestamp": "ISO 8601 string",
  "requestId": "uuid"
}
```

## Authentication Endpoints

### POST /auth/register
Register a new user account.

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "securePassword123",
  "firstName": "John",
  "lastName": "Doe",
  "phoneNumber": "+234801234567",
  "location": {
    "country": "Nigeria",
    "state": "Lagos",
    "lga": "Ikeja"
  },
  "farmingExperience": "beginner|intermediate|advanced",
  "primaryCrops": ["rice", "maize", "cassava"]
}
```

**Response:**
```json
{
  "success": true,
  "data": {
    "user": {
      "id": "uuid",
      "email": "user@example.com",
      "firstName": "John",
      "lastName": "Doe",
      "membershipStatus": "pending",
      "creditScore": 0
    },
    "token": "jwt_token"
  }
}
```

### POST /auth/login
Authenticate user and receive access token.

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "securePassword123"
}
```

### POST /auth/logout
Invalidate current session token.

### POST /auth/refresh
Refresh expired access token using refresh token.

## User Management

### GET /users/profile
Get current user's profile information.

### PUT /users/profile
Update user profile information.

### POST /users/membership/payment
Process membership fee payment.

**Request Body:**
```json
{
  "paymentMethod": "paystack|flutterwave",
  "amount": 5000,
  "currency": "NGN"
}
```

## Course Management

### GET /courses
List available courses with filtering and pagination.

**Query Parameters:**
- `category`: Filter by course category
- `level`: Filter by difficulty level
- `provider`: Filter by course provider
- `page`: Page number (default: 1)
- `limit`: Items per page (default: 20)

**Response:**
```json
{
  "success": true,
  "data": {
    "courses": [
      {
        "id": "uuid",
        "title": "Modern Rice Farming Techniques",
        "description": "Comprehensive guide to rice cultivation",
        "provider": "AgriLearn Academy",
        "category": "crop_production",
        "level": "intermediate",
        "duration": 120,
        "price": 15000,
        "currency": "NGN",
        "rating": 4.8,
        "enrollmentCount": 1250
      }
    ],
    "pagination": {
      "page": 1,
      "limit": 20,
      "total": 150,
      "totalPages": 8
    }
  }
}
```

### GET /courses/:id
Get detailed course information.

### POST /courses/:id/enroll
Enroll in a course.

### GET /courses/enrolled
Get user's enrolled courses.

### POST /courses/:id/progress
Update course progress.

**Request Body:**
```json
{
  "moduleId": "uuid",
  "completed": true,
  "watchTime": 1800,
  "quizScore": 85
}
```

## Quiz System

### GET /quizzes/daily
Get today's daily quiz.

**Response:**
```json
{
  "success": true,
  "data": {
    "quiz": {
      "id": "uuid",
      "date": "2024-03-15",
      "questions": [
        {
          "id": "uuid",
          "question": "What is the optimal pH range for rice cultivation?",
          "options": ["5.5-6.5", "6.0-7.0", "7.0-8.0", "8.0-9.0"],
          "type": "multiple_choice"
        }
      ],
      "timeLimit": 300,
      "pointsAvailable": 10
    }
  }
}
```

### POST /quizzes/:id/submit
Submit quiz answers.

**Request Body:**
```json
{
  "answers": [
    {
      "questionId": "uuid",
      "selectedOption": 1
    }
  ],
  "completionTime": 245
}
```

## Task Engine

### GET /tasks
Get available tasks for the user.

**Response:**
```json
{
  "success": true,
  "data": {
    "tasks": [
      {
        "id": "uuid",
        "title": "Complete Soil Testing Module",
        "description": "Finish the soil testing course module",
        "type": "course_completion",
        "category": "education",
        "points": 50,
        "deadline": "2024-03-20T23:59:59Z",
        "status": "available",
        "requirements": {
          "courseId": "uuid",
          "moduleId": "uuid"
        }
      }
    ]
  }
}
```

### POST /tasks/:id/complete
Mark a task as completed.

### GET /tasks/history
Get user's task completion history.

## Group Management

### GET /groups
List available groups to join.

**Query Parameters:**
- `location`: Filter by location
- `focusArea`: Filter by agricultural focus
- `memberCount`: Filter by group size
- `status`: Filter by group status

### POST /groups
Create a new group.

**Request Body:**
```json
{
  "name": "Lagos Rice Farmers Collective",
  "description": "Focused on modern rice farming techniques",
  "focusArea": "rice_production",
  "location": {
    "country": "Nigeria",
    "state": "Lagos",
    "lga": "Ikeja"
  },
  "membershipFee": 2000,
  "profitSharingRate": 25,
  "maxMembers": 20
}
```

### GET /groups/:id
Get detailed group information.

### POST /groups/:id/join
Join a group.

### POST /groups/:id/leave
Leave a group.

### GET /groups/:id/members
Get group member list (group members only).

### PUT /groups/:id/settings
Update group settings (group leader only).

## Project Management

### GET /groups/:groupId/projects
Get group's collective projects.

### POST /groups/:groupId/projects
Create a new collective project.

**Request Body:**
```json
{
  "title": "Community Rice Processing Center",
  "description": "Establish a shared rice processing facility",
  "category": "equipment",
  "fundingRequired": 500000,
  "currency": "NGN",
  "timeline": {
    "startDate": "2024-04-01",
    "endDate": "2024-12-31"
  },
  "milestones": [
    {
      "title": "Land Acquisition",
      "description": "Secure land for processing center",
      "targetDate": "2024-05-01",
      "fundingAmount": 150000
    }
  ]
}
```

### GET /projects/:id
Get project details.

### PUT /projects/:id/status
Update project status.

### POST /projects/:id/milestones/:milestoneId/complete
Mark project milestone as completed.

## Credit Scoring

### GET /users/credit-score
Get current user's credit score and breakdown.

**Response:**
```json
{
  "success": true,
  "data": {
    "creditScore": 750,
    "scoreBreakdown": {
      "educationalEngagement": 180,
      "taskCompletion": 150,
      "groupParticipation": 200,
      "paymentHistory": 120,
      "projectSuccess": 100
    },
    "scoreHistory": [
      {
        "date": "2024-03-01",
        "score": 720,
        "change": "+30"
      }
    ],
    "recommendations": [
      "Complete more daily quizzes to improve educational engagement",
      "Participate more actively in group discussions"
    ]
  }
}
```

### GET /groups/:groupId/credit-assessment
Get group's collective credit assessment.

## Loan Management

### POST /loans/application
Submit a loan application for collective project.

**Request Body:**
```json
{
  "groupId": "uuid",
  "projectId": "uuid",
  "amount": 500000,
  "currency": "NGN",
  "purpose": "equipment_purchase",
  "repaymentPeriod": 12,
  "collateral": {
    "type": "group_guarantee",
    "description": "Group collective guarantee with equipment as security"
  }
}
```

### GET /loans
Get user's loan applications and active loans.

### GET /loans/:id
Get detailed loan information.

### POST /loans/:id/repayment
Make a loan repayment.

**Request Body:**
```json
{
  "amount": 50000,
  "paymentMethod": "bank_transfer",
  "reference": "TXN123456789"
}
```

## Grant Management

### GET /grants
List available grants.

### POST /grants/:id/apply
Apply for a grant.

**Request Body:**
```json
{
  "groupId": "uuid",
  "projectId": "uuid",
  "requestedAmount": 200000,
  "justification": "Detailed explanation of grant need and impact"
}
```

### GET /grants/applications
Get grant application status.

## Payment Integration

### POST /payments/initialize
Initialize a payment transaction.

**Request Body:**
```json
{
  "amount": 5000,
  "currency": "NGN",
  "purpose": "membership_fee|group_fee|loan_repayment",
  "metadata": {
    "userId": "uuid",
    "groupId": "uuid"
  }
}
```

### POST /payments/verify
Verify payment transaction.

### GET /payments/history
Get payment transaction history.

## Analytics and Reporting

### GET /analytics/dashboard
Get user dashboard analytics.

### GET /analytics/group/:groupId
Get group performance analytics (group members only).

### GET /reports/credit-score
Generate credit score report.

### GET /reports/group-performance
Generate group performance report.

## Webhooks

### POST /webhooks/paystack
Handle Paystack payment webhooks.

### POST /webhooks/flutterwave
Handle Flutterwave payment webhooks.

## Error Codes

| Code | Description |
|------|-------------|
| `AUTH_001` | Invalid credentials |
| `AUTH_002` | Token expired |
| `AUTH_003` | Insufficient permissions |
| `USER_001` | User not found |
| `USER_002` | Email already exists |
| `GROUP_001` | Group not found |
| `GROUP_002` | Already member of a group |
| `GROUP_003` | Group is full |
| `LOAN_001` | Insufficient credit score |
| `LOAN_002` | Loan application pending |
| `PAYMENT_001` | Payment failed |
| `PAYMENT_002` | Insufficient funds |

## Rate Limits

- Authentication endpoints: 5 requests per minute
- General API endpoints: 100 requests per minute
- File upload endpoints: 10 requests per minute

## SDKs and Libraries

Official SDKs are available for:
- JavaScript/Node.js
- Python
- PHP
- React Native (mobile apps)

## Postman Collection

A complete Postman collection with example requests is available at:
`https://api.farmle.com/postman/collection.json`