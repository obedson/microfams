# Deployment Guide

## Overview

This guide covers the production deployment of the Agro-FinTech Credit System, including infrastructure setup, security configurations, and operational procedures for a scalable agricultural education and financing platform.

## Infrastructure Architecture

### Production Environment Stack
- **Application**: Node.js/TypeScript backend, React frontend
- **Database**: PostgreSQL 14+ with Redis caching
- **Web Server**: Nginx reverse proxy
- **Container**: Docker with Docker Compose
- **Cloud Provider**: AWS (primary), Azure (backup)
- **CDN**: CloudFlare for global content delivery

### Environment Tiers
1. **Production**: Live user-facing environment
2. **Staging**: Pre-production testing environment
3. **Development**: Developer testing environment
4. **Testing**: Automated testing environment

## Prerequisites

### System Requirements
- **CPU**: 4+ cores (production), 2+ cores (staging)
- **RAM**: 8GB+ (production), 4GB+ (staging)
- **Storage**: 100GB+ SSD with backup capability
- **Network**: Stable internet with SSL certificate support

### Required Software
```bash
# Core dependencies
- Docker 20.10+
- Docker Compose 2.0+
- Node.js 18+ (for local development)
- PostgreSQL 14+ (if not using Docker)
- Redis 6+ (if not using Docker)
- Nginx 1.20+

# Monitoring and logging
- PM2 (process management)
- Logrotate (log management)
- Fail2ban (security)
```

### Domain and SSL
- Registered domain name (e.g., farmle.com)
- SSL certificate (Let's Encrypt recommended)
- DNS configuration with CloudFlare

## Environment Configuration

### Environment Variables

Create `.env.production` file:
```bash
# Application
NODE_ENV=production
PORT=3000
API_VERSION=v1

# Database
DATABASE_URL=postgresql://username:password@localhost:5432/farmle_prod
REDIS_URL=redis://localhost:6379

# Security
JWT_SECRET=your-super-secure-jwt-secret-key
JWT_REFRESH_SECRET=your-refresh-token-secret
BCRYPT_ROUNDS=12
CSRF_SECRET=your-csrf-secret-key

# Payment Gateways
PAYSTACK_SECRET_KEY=sk_live_your_paystack_secret
PAYSTACK_PUBLIC_KEY=pk_live_your_paystack_public
FLUTTERWAVE_SECRET_KEY=FLWSECK_TEST-your_flutterwave_secret
FLUTTERWAVE_PUBLIC_KEY=FLWPUBK_TEST-your_flutterwave_public

# External Services
AWS_ACCESS_KEY_ID=your_aws_access_key
AWS_SECRET_ACCESS_KEY=your_aws_secret_key
AWS_REGION=us-east-1
S3_BUCKET_NAME=farmle-uploads

# Email Service
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=noreply@farmle.com
SMTP_PASS=your_email_password

# Monitoring
SENTRY_DSN=https://your_sentry_dsn
LOG_LEVEL=info

# Rate Limiting
RATE_LIMIT_WINDOW_MS=900000
RATE_LIMIT_MAX_REQUESTS=100

# File Upload
MAX_FILE_SIZE=10485760
ALLOWED_FILE_TYPES=jpg,jpeg,png,pdf,doc,docx
```

### Database Configuration

PostgreSQL production settings in `postgresql.conf`:
```sql
# Connection settings
max_connections = 200
shared_buffers = 2GB
effective_cache_size = 6GB
work_mem = 16MB
maintenance_work_mem = 512MB

# Write-ahead logging
wal_buffers = 16MB
checkpoint_completion_target = 0.9
wal_level = replica
max_wal_senders = 3

# Query performance
random_page_cost = 1.1
effective_io_concurrency = 200
```

## Docker Deployment

### Production Docker Compose

Create `docker-compose.prod.yml`:
```yaml
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.prod
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
    env_file:
      - .env.production
    depends_on:
      - postgres
      - redis
    restart: unless-stopped
    volumes:
      - ./logs:/app/logs
      - ./uploads:/app/uploads

  postgres:
    image: postgres:14-alpine
    environment:
      POSTGRES_DB: farmle_prod
      POSTGRES_USER: farmle_user
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./backups:/backups
    ports:
      - "5432:5432"
    restart: unless-stopped

  redis:
    image: redis:6-alpine
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    ports:
      - "6379:6379"
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./nginx/ssl:/etc/nginx/ssl
      - ./static:/var/www/static
    depends_on:
      - app
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
```

### Production Dockerfile

Create `Dockerfile.prod`:
```dockerfile
FROM node:18-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

FROM node:18-alpine AS production

RUN addgroup -g 1001 -S nodejs
RUN adduser -S farmle -u 1001

WORKDIR /app

COPY --from=builder --chown=farmle:nodejs /app/dist ./dist
COPY --from=builder --chown=farmle:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=farmle:nodejs /app/package.json ./package.json

USER farmle

EXPOSE 3000

CMD ["node", "dist/index.js"]
```

## Nginx Configuration

### Main Nginx Config

Create `nginx/nginx.conf`:
```nginx
events {
    worker_connections 1024;
}

http {
    upstream app {
        server app:3000;
    }

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/s;

    # SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    server {
        listen 80;
        server_name farmle.com www.farmle.com;
        return 301 https://$server_name$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name farmle.com www.farmle.com;

        ssl_certificate /etc/nginx/ssl/farmle.com.crt;
        ssl_certificate_key /etc/nginx/ssl/farmle.com.key;

        # Security headers
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";

        # API routes
        location /api/ {
            limit_req zone=api burst=20 nodelay;
            proxy_pass http://app;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Authentication routes (stricter rate limiting)
        location /api/auth/ {
            limit_req zone=auth burst=10 nodelay;
            proxy_pass http://app;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Static files
        location /static/ {
            alias /var/www/static/;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        # Health check
        location /health {
            access_log off;
            return 200 "healthy\n";
        }
    }
}
```

## Database Setup

### Initial Database Setup
```bash
# Create database and user
sudo -u postgres psql
CREATE DATABASE farmle_prod;
CREATE USER farmle_user WITH ENCRYPTED PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE farmle_prod TO farmle_user;
\q

# Run migrations
npm run migrate:prod
```

### Database Backup Script

Create `scripts/backup-db.sh`:
```bash
#!/bin/bash

# Configuration
DB_NAME="farmle_prod"
DB_USER="farmle_user"
BACKUP_DIR="/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/farmle_backup_$DATE.sql"

# Create backup directory if it doesn't exist
mkdir -p $BACKUP_DIR

# Create backup
pg_dump -h localhost -U $DB_USER -d $DB_NAME > $BACKUP_FILE

# Compress backup
gzip $BACKUP_FILE

# Remove backups older than 30 days
find $BACKUP_DIR -name "farmle_backup_*.sql.gz" -mtime +30 -delete

echo "Backup completed: $BACKUP_FILE.gz"
```

## Deployment Process

### Automated Deployment Script

Create `scripts/deploy.sh`:
```bash
#!/bin/bash

set -e

echo "Starting deployment..."

# Pull latest code
git pull origin main

# Build and deploy
docker-compose -f docker-compose.prod.yml down
docker-compose -f docker-compose.prod.yml build --no-cache
docker-compose -f docker-compose.prod.yml up -d

# Run database migrations
docker-compose -f docker-compose.prod.yml exec app npm run migrate

# Health check
sleep 30
curl -f http://localhost/health || exit 1

echo "Deployment completed successfully!"
```

### Zero-Downtime Deployment

For production environments requiring zero downtime:
```bash
#!/bin/bash

# Blue-green deployment script
CURRENT_ENV=$(docker-compose -f docker-compose.prod.yml ps -q app | head -1)
NEW_ENV="green"

if [ "$CURRENT_ENV" == "green" ]; then
    NEW_ENV="blue"
fi

# Deploy to new environment
docker-compose -f docker-compose.$NEW_ENV.yml up -d

# Health check new environment
sleep 30
curl -f http://localhost:8080/health || exit 1

# Switch traffic
nginx -s reload

# Stop old environment
docker-compose -f docker-compose.$CURRENT_ENV.yml down

echo "Zero-downtime deployment completed!"
```

## Security Configuration

### Firewall Setup (UFW)
```bash
# Enable firewall
sudo ufw enable

# Allow SSH
sudo ufw allow 22/tcp

# Allow HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Allow database (only from app server)
sudo ufw allow from 10.0.0.0/8 to any port 5432

# Deny all other traffic
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

### Fail2Ban Configuration

Create `/etc/fail2ban/jail.local`:
```ini
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 3
```

## Monitoring and Logging

### Application Monitoring

Install and configure monitoring tools:
```bash
# Install PM2 for process management
npm install -g pm2

# Create PM2 ecosystem file
cat > ecosystem.config.js << EOF
module.exports = {
  apps: [{
    name: 'farmle-api',
    script: 'dist/index.js',
    instances: 'max',
    exec_mode: 'cluster',
    env: {
      NODE_ENV: 'production'
    },
    error_file: './logs/err.log',
    out_file: './logs/out.log',
    log_file: './logs/combined.log',
    time: true
  }]
}
EOF

# Start application with PM2
pm2 start ecosystem.config.js
pm2 save
pm2 startup
```

### Log Management

Configure log rotation in `/etc/logrotate.d/farmle`:
```
/app/logs/*.log {
    daily
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 644 farmle farmle
    postrotate
        pm2 reloadLogs
    endscript
}
```

### Health Monitoring Script

Create `scripts/health-check.sh`:
```bash
#!/bin/bash

# Health check endpoints
API_HEALTH="https://farmle.com/health"
DB_HEALTH="https://farmle.com/api/health/db"

# Check API health
if ! curl -f $API_HEALTH > /dev/null 2>&1; then
    echo "API health check failed" | mail -s "Farmle API Down" admin@farmle.com
    exit 1
fi

# Check database health
if ! curl -f $DB_HEALTH > /dev/null 2>&1; then
    echo "Database health check failed" | mail -s "Farmle DB Issue" admin@farmle.com
    exit 1
fi

echo "All health checks passed"
```

## Performance Optimization

### Database Optimization
```sql
-- Create performance indexes
CREATE INDEX CONCURRENTLY idx_users_active ON users(id) WHERE membership_status = 'active';
CREATE INDEX CONCURRENTLY idx_groups_location_active ON groups(country, state) WHERE status = 'active';

-- Analyze tables for query optimization
ANALYZE users;
ANALYZE groups;
ANALYZE collective_projects;
```

### Redis Configuration

Optimize Redis for production in `redis.conf`:
```
# Memory management
maxmemory 2gb
maxmemory-policy allkeys-lru

# Persistence
save 900 1
save 300 10
save 60 10000

# Network
tcp-keepalive 300
timeout 0
```

## Backup and Recovery

### Automated Backup Cron Jobs

Add to crontab (`crontab -e`):
```bash
# Database backup every 6 hours
0 */6 * * * /app/scripts/backup-db.sh

# File backup daily at 2 AM
0 2 * * * rsync -av /app/uploads/ /backups/uploads/

# Log cleanup weekly
0 3 * * 0 find /app/logs -name "*.log" -mtime +7 -delete
```

### Disaster Recovery Procedure

1. **Immediate Response** (0-15 minutes)
   - Assess the scope of the outage
   - Activate incident response team
   - Switch to backup infrastructure if needed

2. **Recovery Process** (15-60 minutes)
   - Restore from latest backup
   - Verify data integrity
   - Run health checks

3. **Post-Recovery** (1-4 hours)
   - Monitor system stability
   - Conduct post-mortem analysis
   - Update documentation

## Scaling Considerations

### Horizontal Scaling
- Load balancer configuration for multiple app instances
- Database read replicas for improved performance
- Redis clustering for session management

### Vertical Scaling
- Monitor CPU and memory usage
- Upgrade server resources as needed
- Optimize database queries and indexes

### Auto-scaling Configuration

For cloud deployments, configure auto-scaling:
```yaml
# AWS Auto Scaling Group
AutoScalingGroup:
  MinSize: 2
  MaxSize: 10
  DesiredCapacity: 2
  TargetGroupARNs:
    - !Ref ApplicationLoadBalancerTargetGroup
  HealthCheckType: ELB
  HealthCheckGracePeriod: 300
```

## Maintenance Procedures

### Regular Maintenance Tasks

**Daily:**
- Monitor system health and performance
- Review error logs and alerts
- Verify backup completion

**Weekly:**
- Update system packages
- Review security logs
- Performance optimization review

**Monthly:**
- Security audit and vulnerability assessment
- Capacity planning review
- Disaster recovery testing

### Update Procedures

1. **Security Updates** (immediate)
2. **Minor Updates** (weekly maintenance window)
3. **Major Updates** (planned maintenance with user notification)

## Troubleshooting

### Common Issues and Solutions

**High CPU Usage:**
```bash
# Check process usage
top -p $(pgrep -d',' node)

# Restart application if needed
pm2 restart farmle-api
```

**Database Connection Issues:**
```bash
# Check PostgreSQL status
sudo systemctl status postgresql

# Check connection limits
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"
```

**Memory Issues:**
```bash
# Check memory usage
free -h

# Clear Redis cache if needed
redis-cli FLUSHALL
```

### Emergency Contacts

- **System Administrator**: admin@farmle.com
- **Database Administrator**: dba@farmle.com
- **Security Team**: security@farmle.com
- **On-call Engineer**: +234-XXX-XXX-XXXX

This deployment guide provides a comprehensive foundation for running the Agro-FinTech Credit System in production. Regular updates and monitoring ensure optimal performance and security.