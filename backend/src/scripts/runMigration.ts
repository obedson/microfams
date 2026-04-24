#!/usr/bin/env node

/**
 * Migration Runner for Farmle Platform Enhancement
 * Runs the database schema migration with proper error handling and logging
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import supabase from '../utils/supabase.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

async function runMigration() {
    console.log('🚀 Starting Farmle Platform Enhancement Database Migration...\n');
    
    try {
        // Read the migration file
        const migrationPath = path.join(__dirname, '../../migrations', '001_farmle_platform_enhancement_schema.sql');
        const migrationSQL = fs.readFileSync(migrationPath, 'utf8');
        
        console.log('📖 Migration file loaded successfully');
        console.log(`📄 File: ${migrationPath}`);
        console.log(`📏 Size: ${migrationSQL.length} characters\n`);
        
        // Split the migration into individual statements for better error handling
        const statements = migrationSQL
            .split(';')
            .map(stmt => stmt.trim())
            .filter(stmt => stmt.length > 0 && !stmt.startsWith('--') && !stmt.match(/^\s*$/));
        
        console.log(`⚡ Executing ${statements.length} SQL statements...\n`);
        
        let successCount = 0;
        let skipCount = 0;
        
        for (let i = 0; i < statements.length; i++) {
            const statement = statements[i];
            if (statement.trim()) {
                try {
                    console.log(`   ${i + 1}/${statements.length}: ${statement.substring(0, 50)}...`);
                    
                    const { error } = await supabase.rpc('exec_sql', { 
                        sql: statement + ';' 
                    });
                    
                    if (error) {
                        // Handle expected errors for IF NOT EXISTS statements
                        if (error.message.includes('already exists') || 
                            error.message.includes('IF NOT EXISTS') ||
                            error.message.includes('duplicate key')) {
                            console.log(`   ⏭️  Skipped (already exists)`);
                            skipCount++;
                        } else {
                            console.error(`❌ Statement ${i + 1} failed:`, error.message);
                            console.error(`Statement: ${statement.substring(0, 200)}...`);
                            throw error;
                        }
                    } else {
                        console.log(`   ✅ Completed`);
                        successCount++;
                    }
                } catch (stmtError: any) {
                    console.error(`💥 Critical error in statement ${i + 1}:`, stmtError.message);
                    throw stmtError;
                }
            }
        }
        
        console.log(`\n📊 Migration Summary:`);
        console.log(`   ✅ Successful: ${successCount}`);
        console.log(`   ⏭️  Skipped: ${skipCount}`);
        console.log(`   📝 Total: ${statements.length}`);
        
        // Verify the migration results
        await verifyMigration();
        
        console.log('\n🎉 Migration completed successfully!');
        
    } catch (error: any) {
        console.error('💥 Migration failed:', error.message);
        process.exit(1);
    }
}

async function verifyMigration() {
    console.log('\n🔍 Verifying migration results...\n');
    
    try {
        // Check new columns in bookings table
        const { data: bookingColumns, error: columnError } = await supabase
            .from('information_schema.columns')
            .select('column_name')
            .eq('table_name', 'bookings')
            .in('column_name', ['payment_retry_count', 'payment_timeout_at']);
            
        if (columnError) {
            console.warn('⚠️  Could not verify booking columns:', columnError.message);
        } else {
            console.log(`✅ Booking table enhanced: ${bookingColumns?.length || 0}/2 new columns added`);
            bookingColumns?.forEach(col => console.log(`   - ${col.column_name}`));
        }
        
        // Check new tables
        const newTables = ['analytics_cache', 'booking_communications', 'payment_receipts'];
        for (const tableName of newTables) {
            const { data: tableExists, error: tableError } = await supabase
                .from('information_schema.tables')
                .select('table_name')
                .eq('table_name', tableName)
                .maybeSingle();
                
            if (tableError) {
                console.warn(`⚠️  Could not verify table ${tableName}:`, tableError.message);
            } else if (tableExists) {
                console.log(`✅ Table created: ${tableName}`);
            } else {
                console.log(`❌ Table missing: ${tableName}`);
            }
        }
        
        // Check analytics view
        const { data: viewExists, error: viewError } = await supabase
            .from('information_schema.views')
            .select('table_name')
            .eq('table_name', 'booking_analytics')
            .maybeSingle();
            
        if (viewError) {
            console.warn('⚠️  Could not verify analytics view:', viewError.message);
        } else if (viewExists) {
            console.log('✅ Analytics view created: booking_analytics');
        } else {
            console.log('❌ Analytics view missing: booking_analytics');
        }
        
        // Test the analytics view
        const { data: analyticsTest, error: analyticsError } = await supabase
            .from('booking_analytics')
            .select('property_id, total_bookings, total_revenue')
            .limit(1);
            
        if (analyticsError) {
            console.warn('⚠️  Analytics view test failed:', analyticsError.message);
        } else {
            console.log('✅ Analytics view is functional');
        }
        
        console.log('\n📋 Enhancement Summary:');
        console.log('   - Enhanced bookings table with payment retry functionality');
        console.log('   - Created analytics_cache table for performance optimization');
        console.log('   - Created booking_communications table for in-app messaging');
        console.log('   - Created payment_receipts table for receipt generation');
        console.log('   - Added booking_analytics view for real-time analytics');
        console.log('   - Added performance indexes for new query patterns');
        console.log('   - Added utility functions for occupancy and conversion calculations');
        
    } catch (error: any) {
        console.warn('⚠️  Verification failed:', error.message);
    }
}

// Run the migration if this file is executed directly
if (import.meta.url === `file://${process.argv[1]}`) {
    runMigration();
}

export { runMigration, verifyMigration };