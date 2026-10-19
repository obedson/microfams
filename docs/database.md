# Database Documentation

## Overview

The Agro-FinTech Credit System uses PostgreSQL as the primary database with Redis for caching and session management. The database is designed to support multi-tenancy, scalability, and data integrity for agricultural education and financing operations.

## Database Architecture

### Primary Database: PostgreSQL 14+
- **Purpose**: Transactional data, user management, financial records
- **Features**: ACID compliance, advanced indexing, JSON support
- **Scaling**: Read replicas, connection pooling

### Cache Layer: Redis 6+
- **Purpose**: Session storage, real-time data, temporary calculations
- **Features**: In-memory performance, pub/sub messaging
- **Scaling**: Redis Cluster for high availability

### Future Considerations: Apache Kafka
- **Trigger**: 50,000+ active farmers
- **Purpose**: Event streaming, real-time analytics
- **Integration**: Gradual migration from Redis pub/sub

## Core Tables Structure

### Users and Authentication

#### users
Primary user account information and profile data.

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone_number VARCHAR(20),
    date_of_birth DATE,
    gender VARCHAR(10),
    
    -- Location information
    country VARCHAR(100) NOT NULL,
    state VARCHAR(100),
    lga VARCHAR(100),
    address TEXT,
    
    -- Farming profile
    farming_experience VARCHAR(20) CHECK (farming_experience IN ('beginner', 'intermediate', 'advanced')),
    primary_crops JSONB,
    farm_size_hectares DECIMAL(10,2),
    
    -- Platform status
    membership_status VARCHAR(20) DEFAULT 'pending' CHECK (membership_status IN ('pending', 'active', 'suspended', 'inactive')),
    membership_paid_at TIMESTAMP,
    email_verified BOOLEAN DEFAULT FALSE,
    phone_verified BOOLEAN DEFAULT FALSE,
    
    -- Timestamps
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login_at TIMESTAMP
);
```

#### user_sessions
Active user sessions and authentication tokens.

```sql
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    refresh_token_hash VARCHAR(255),
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_used_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ip_address INET,
    user_agent TEXT
);
```
### Course Management

#### courses
External course catalog and metadata.

```sql
CREATE TABLE courses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    provider VARCHAR(100) NOT NULL,
    external_id VARCHAR(100),
    external_url TEXT,
    
    -- Course details
    category VARCHAR(50) NOT NULL,
    level VARCHAR(20) CHECK (level IN ('beginner', 'intermediate', 'advanced')),
    duration_minutes INTEGER,
    price DECIMAL(10,2),
    currency VARCHAR(3) DEFAULT 'NGN',
    
    -- Metadata
    rating DECIMAL(3,2),
    enrollment_count INTEGER DEFAULT 0,
    tags JSONB,
    prerequisites JSONB,
    
    -- Status
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'archived')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### course_enrollments
User course enrollment and progress tracking.

```sql
CREATE TABLE course_enrollments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    course_id UUID REFERENCES courses(id) ON DELETE CASCADE,
    
    -- Progress tracking
    progress_percentage DECIMAL(5,2) DEFAULT 0,
    completed_at TIMESTAMP,
    last_accessed_at TIMESTAMP,
    total_watch_time INTEGER DEFAULT 0,
    
    -- Payment
    payment_status VARCHAR(20) DEFAULT 'pending' CHECK (payment_status IN ('pending', 'paid', 'refunded')),
    payment_amount DECIMAL(10,2),
    payment_reference VARCHAR(100),
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE(user_id, course_id)
);
```

### Quiz and Assessment System

#### daily_quizzes
Daily quiz questions and metadata.

```sql
CREATE TABLE daily_quizzes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quiz_date DATE NOT NULL UNIQUE,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    questions JSONB NOT NULL, -- Array of question objects
    time_limit_seconds INTEGER DEFAULT 300,
    points_available INTEGER DEFAULT 10,
    difficulty_level VARCHAR(20) DEFAULT 'intermediate',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### quiz_submissions
User quiz submission records and scores.

```sql
CREATE TABLE quiz_submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    quiz_id UUID REFERENCES daily_quizzes(id) ON DELETE CASCADE,
    
    -- Submission data
    answers JSONB NOT NULL,
    score INTEGER NOT NULL,
    max_score INTEGER NOT NULL,
    completion_time_seconds INTEGER,
    
    submitted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE(user_id, quiz_id)
);
```

### Task Engine

#### tasks
Available tasks for users to complete.

```sql
CREATE TABLE tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    type VARCHAR(50) NOT NULL, -- course_completion, quiz_participation, group_activity, etc.
    category VARCHAR(50) NOT NULL,
    
    -- Task configuration
    points INTEGER DEFAULT 0,
    requirements JSONB, -- Task-specific requirements
    deadline TIMESTAMP,
    recurring BOOLEAN DEFAULT FALSE,
    recurring_pattern VARCHAR(50), -- daily, weekly, monthly
    
    -- Availability
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'archived')),
    target_audience JSONB, -- User criteria for task availability
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### task_completions
User task completion records.

```sql
CREATE TABLE task_completions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    task_id UUID REFERENCES tasks(id) ON DELETE CASCADE,
    
    -- Completion data
    completed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    points_earned INTEGER DEFAULT 0,
    completion_data JSONB, -- Task-specific completion details
    verified BOOLEAN DEFAULT FALSE,
    verified_by UUID REFERENCES users(id),
    verified_at TIMESTAMP,
    
    UNIQUE(user_id, task_id, completed_at::date) -- Prevent duplicate daily completions
);
```

### Group Management

#### groups
Agricultural collaboration groups.

```sql
CREATE TABLE groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    
    -- Group configuration
    focus_area VARCHAR(100), -- rice_production, livestock, etc.
    membership_fee DECIMAL(10,2) DEFAULT 0,
    profit_sharing_rate DECIMAL(5,2) CHECK (profit_sharing_rate BETWEEN 10 AND 40),
    max_members INTEGER DEFAULT 20,
    
    -- Location
    country VARCHAR(100) NOT NULL,
    state VARCHAR(100),
    lga VARCHAR(100),
    
    -- Leadership
    leader_id UUID REFERENCES users(id),
    co_leader_id UUID REFERENCES users(id),
    
    -- Status and metrics
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended')),
    member_count INTEGER DEFAULT 0,
    total_projects INTEGER DEFAULT 0,
    success_rate DECIMAL(5,2) DEFAULT 0,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### group_memberships
User membership in groups.

```sql
CREATE TABLE group_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
    
    -- Membership details
    role VARCHAR(20) DEFAULT 'member' CHECK (role IN ('leader', 'co_leader', 'member')),
    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    left_at TIMESTAMP,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended')),
    
    -- Payment
    membership_fee_paid DECIMAL(10,2),
    payment_reference VARCHAR(100),
    payment_date TIMESTAMP,
    
    UNIQUE(user_id, group_id, left_at) -- One active membership per user per group
);
```

### Project and Loan Management

#### collective_projects
Group collective projects for funding.

```sql
CREATE TABLE collective_projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
    
    -- Project details
    title VARCHAR(255) NOT NULL,
    description TEXT,
    category VARCHAR(50) NOT NULL, -- equipment, space_booking, inputs, etc.
    
    -- Funding
    funding_required DECIMAL(12,2) NOT NULL,
    funding_secured DECIMAL(12,2) DEFAULT 0,
    currency VARCHAR(3) DEFAULT 'NGN',
    
    -- Timeline
    start_date DATE,
    end_date DATE,
    status VARCHAR(20) DEFAULT 'planning' CHECK (status IN ('planning', 'funding', 'active', 'completed', 'cancelled')),
    
    -- Milestones and tracking
    milestones JSONB,
    progress_percentage DECIMAL(5,2) DEFAULT 0,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### loan_applications
Collective project loan applications.

```sql
CREATE TABLE loan_applications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
    project_id UUID REFERENCES collective_projects(id) ON DELETE CASCADE,
    
    -- Loan details
    amount DECIMAL(12,2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'NGN',
    purpose TEXT NOT NULL,
    repayment_period_months INTEGER NOT NULL,
    
    -- Risk assessment
    group_credit_score INTEGER,
    risk_assessment JSONB,
    collateral_description TEXT,
    
    -- Application status
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'under_review', 'approved', 'rejected', 'disbursed')),
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMP,
    reviewed_by UUID REFERENCES users(id),
    
    -- Loan terms (if approved)
    interest_rate DECIMAL(5,2),
    origination_fee DECIMAL(5,2),
    monthly_payment DECIMAL(10,2),
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Credit Scoring System

#### credit_scores
User credit score tracking and history.

```sql
CREATE TABLE credit_scores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    
    -- Score components
    total_score INTEGER NOT NULL,
    educational_engagement INTEGER DEFAULT 0,
    task_completion INTEGER DEFAULT 0,
    group_participation INTEGER DEFAULT 0,
    payment_history INTEGER DEFAULT 0,
    project_success INTEGER DEFAULT 0,
    
    -- Calculation metadata
    calculation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    factors_considered JSONB,
    recommendations JSONB,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### group_credit_assessments
Group collective credit assessments.

```sql
CREATE TABLE group_credit_assessments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
    
    -- Assessment scores
    collective_score INTEGER NOT NULL,
    leadership_score INTEGER DEFAULT 0,
    member_engagement_score INTEGER DEFAULT 0,
    project_history_score INTEGER DEFAULT 0,
    financial_discipline_score INTEGER DEFAULT 0,
    
    -- Assessment details
    assessment_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    assessed_by UUID REFERENCES users(id),
    risk_factors JSONB,
    strengths JSONB,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## Indexes and Performance

### Primary Indexes
```sql
-- User lookups
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_phone ON users(phone_number);
CREATE INDEX idx_users_location ON users(country, state, lga);

-- Course and enrollment queries
CREATE INDEX idx_courses_category_level ON courses(category, level);
CREATE INDEX idx_course_enrollments_user ON course_enrollments(user_id);
CREATE INDEX idx_course_enrollments_progress ON course_enrollments(user_id, progress_percentage);

-- Quiz performance
CREATE INDEX idx_daily_quizzes_date ON daily_quizzes(quiz_date);
CREATE INDEX idx_quiz_submissions_user_date ON quiz_submissions(user_id, submitted_at);

-- Task system
CREATE INDEX idx_tasks_type_status ON tasks(type, status);
CREATE INDEX idx_task_completions_user_date ON task_completions(user_id, completed_at);

-- Group operations
CREATE INDEX idx_groups_location ON groups(country, state, lga);
CREATE INDEX idx_group_memberships_user ON group_memberships(user_id, status);
CREATE INDEX idx_group_memberships_group ON group_memberships(group_id, status);

-- Credit scoring
CREATE INDEX idx_credit_scores_user_date ON credit_scores(user_id, calculation_date DESC);
CREATE INDEX idx_group_assessments_date ON group_credit_assessments(group_id, assessment_date DESC);
```

### Composite Indexes for Complex Queries
```sql
-- Multi-tenant course filtering
CREATE INDEX idx_courses_filter ON courses(status, category, level, provider);

-- User activity tracking
CREATE INDEX idx_user_activity ON task_completions(user_id, completed_at DESC, points_earned);

-- Group project funding
CREATE INDEX idx_project_funding ON collective_projects(group_id, status, funding_required);

-- Loan application processing
CREATE INDEX idx_loan_apps_status ON loan_applications(status, applied_at);
```

## Data Relationships

### Key Foreign Key Constraints
- Users can have multiple course enrollments
- Users can be members of only ONE active group
- Groups can have multiple collective projects
- Projects can have multiple loan applications
- Credit scores maintain historical records per user

### Referential Integrity Rules
- Cascade deletes for user-dependent data
- Restrict deletes for financial records
- Soft deletes for audit trail preservation

## Data Migration Strategy

### Phase 1: Core Platform (0-10K users)
- Single PostgreSQL instance
- Basic Redis caching
- Manual backup procedures

### Phase 2: Growth (10K-50K users)
- Read replica implementation
- Redis clustering
- Automated backup and monitoring

### Phase 3: Scale (50K+ users)
- Database sharding by region
- Apache Kafka integration
- Advanced analytics pipeline

## Backup and Recovery

### Backup Strategy
- **Frequency**: Daily full backups, hourly incremental
- **Retention**: 30 days local, 1 year archive
- **Testing**: Monthly restore validation

### Disaster Recovery
- **RTO**: 4 hours maximum downtime
- **RPO**: 1 hour maximum data loss
- **Failover**: Automated to secondary region

## Security Considerations

### Data Encryption
- **At Rest**: AES-256 encryption for sensitive fields
- **In Transit**: TLS 1.3 for all connections
- **Application**: bcrypt for password hashing

### Access Control
- **Database**: Role-based access with minimal privileges
- **Application**: JWT-based authentication
- **Audit**: Comprehensive logging of data access

### Compliance
- **Nigeria**: CBN guidelines, NDPR compliance
- **International**: GDPR readiness for expansion
- **Financial**: PCI DSS for payment processing

## Monitoring and Maintenance

### Performance Monitoring
- Query performance analysis
- Index usage statistics
- Connection pool monitoring
- Cache hit rate tracking

### Maintenance Tasks
- **Daily**: Log rotation, backup verification
- **Weekly**: Index maintenance, statistics update
- **Monthly**: Performance review, capacity planning
- **Quarterly**: Security audit, disaster recovery testing