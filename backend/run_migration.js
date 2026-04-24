#!/usr/bin/env node

/**
 * Migration Runner for Farmle Platform Enhancement
 * Runs the database schema migration with proper error handling and logging
 */

const fs = require('fs');
const path = require('path');
require('dotenv').config();

// Import database connection (assuming existing setup)
const { createClient } = require('@supabase/supabase-js');

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseServiceKey) {
    console.error('❌ Missing required environment variables: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
    process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseServiceKey);

async function runMigration() {
    console.log('🚀 Starting Farmle Platform Enhancement Database Migration...\n');
    
    try {
        // Read the migration file
        const migrationPath = path.join(__dirname, 'migrations', '001_farmle_platform_enhancement_schema.sql');
        const migrationSQL = fs.readFileSync(migrationPath, 'utf8');
        
        console.log('📖 Migration file loaded successfully');
        console.log(`📄 File: ${migrationPath}`);
        console.log(`📏 Size: ${migrationSQL.length} characters\n`);
        
        // Execute the migration
        console.log('⚡ Executing migration...');
        const { data, error } = await supabase.rpc('exec_sql', { sql: migrationSQL });
        
        if (error) {
            console.error('❌ Migration failed:', error);
            process.exit(1);
        }
        
        console.log('✅ Migration executed successfully!\n');
        
        // Verify the migration by checking new tables and columns
        console.log('🔍 Verifying migration results...\n');
        
        // Check new columns in bookings table
        const { data: bookingColumns, error: columnError } = await supabase
            .from('information_schema.columns')
            .select('column_name')
            .eq('table_name', 'bookings')
            .in('column_name', ['payment_retry_count', 'payment_timeout_at']);
            
        if (columnError) {
            console.warn('⚠️  Could not verify booking columns:', columnError.message);
        } else {
            console.log(`✅ Booking table enhanced: ${bookingColumns.length}/2 new columns added`);
            bookingColumns.forEach(col => console.log(`   - ${col.column_name}`));
        }
        
        // Check new tables
        const newTables = ['analytics_cache', 'booking_communications', 'payment_receipts'];
        for (const tableName of newTables) {
            const { data: tableExists, error: tableError } = await supabase
                .from('information_schema.tables')
                .select('table_name')
                .eq('table_name', tableName)
                .single();
                
            if (tableError) {
                console.warn(`⚠️  Could not verify table ${tableName}:`, tableError.message);
            } else if (tableExists) {
                console.log(`✅ Table created: ${tableName}`);
            }
        }
        
        // Check analytics view
        const { data: viewExists, error: viewError } = await supabase
            .from('information_schema.views')
            .select('table_name')
            .eq('table_name', 'booking_analytics')
            .single();
            
        if (viewError) {
            console.warn('⚠️  Could not verify analytics view:', viewError.message);
        } else if (viewExists) {
            console.log('✅ Analytics view created: booking_analytics');
        }
        
        console.log('\n🎉 Migration completed successfully!');
        console.log('\n📊 Summary:');
        console.log('   - Enhanced bookings table with payment retry functionality');
        console.log('   - Created analytics_cache table for performance optimization');
        console.log('   - Created booking_communications table for in-app messaging');
        console.log('   - Created payment_receipts table for receipt generation');
        console.log('   - Added booking_analytics view for real-time analytics');
        console.log('   - Added performance indexes for new query patterns');
        console.log('   - Added utility functions for occupancy and conversion calculations');
        
    } catch (error) {
        console.error('💥 Unexpected error during migration:', error);
        process.exit(1);
    }
}

// Alternative method using direct SQL execution if rpc is not available
async function runMigrationDirect() {
    console.log('🚀 Starting Farmle Platform Enhancement Database Migration (Direct SQL)...\n');
    
    try {
        const migrationPath = path.join(__dirname, 'migrations', '001_farmle_platform_enhancement_schema.sql');
        const migrationSQL = fs.readFileSync(migrationPath, 'utf8');
        
        console.log('📖 Migration file loaded successfully');
        console.log(`📄 File: ${migrationPath}`);
        console.log(`📏 Size: ${migrationSQL.length} characters\n`);
        
        // Split the migration into individual statements
        const statements = migrationSQL
            .split(';')
            .map(stmt => stmt.trim())
            .filter(stmt => stmt.length > 0 && !stmt.startsWith('--'));
        
        console.log(`⚡ Executing ${statements.length} SQL statements...\n`);
        
        for (let i = 0; i < statements.length; i++) {
            const statement = statements[i];
            if (statement.trim()) {
                try {
                    console.log(`   ${i + 1}/${statements.length}: Executing statement...`);
                    const { error } = await supabase.rpc('exec_sql', { sql: statement + ';' });
                    
                    if (error) {
                        console.error(`❌ Statement ${i + 1} failed:`, error);
                        console.error(`Statement: ${statement.substring(0, 100)}...`);
                        // Continue with other statements for non-critical errors
                        if (error.message.includes('already exists') || error.message.includes('IF NOT EXISTS')) {
                            console.log('   ℹ️  Continuing (object already exists)...');
                        } else {
                            throw error;
                        }
                    } else {
                        console.log(`   ✅ Statement ${i + 1} completed`);
                    }
                } catch (stmtError) {
                    console.error(`💥 Critical error in statement ${i + 1}:`, stmtError);
                    throw stmtError;
                }
            }
        }
        
        console.log('\n🎉 Migration completed successfully!');
        
    } catch (error) {
        console.error('💥 Migration failed:', error);
        process.exit(1);
    }
}

// Run the migration
if (require.main === module) {
    runMigration().catch(() => {
        console.log('\n🔄 Trying alternative migration method...');
        runMigrationDirect();
    });
}

module.exports = { runMigration, runMigrationDirect };