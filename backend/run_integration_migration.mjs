import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import { supabase } from './src/utils/supabase.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

async function runMigration() {
    console.log('🚀 Starting Integration Columns Migration...\n');
    
    try {
        const migrationPath = path.join(__dirname, 'migrations', 'add_integration_columns.sql');
        const sql = fs.readFileSync(migrationPath, 'utf8');
        
        // Split by semicolon and run each statement
        const statements = sql
            .split(';')
            .map(s => s.trim())
            .filter(s => s.length > 0);
            
        for (const statement of statements) {
            console.log(`📝 Executing: ${statement.substring(0, 50)}...`);
            const { error } = await supabase.rpc('exec_sql', { sql: statement + ';' });
            if (error) {
                if (error.message.includes('already exists')) {
                    console.log('   ℹ️  Already exists, skipping.');
                } else {
                    console.error('   ❌ Error:', error.message);
                    // Continue anyway as some might succeed
                }
            } else {
                console.log('   ✅ Success');
            }
        }
        
        console.log('\n🎉 Migration completed!');
    } catch (error) {
        console.error('💥 Migration failed:', error.message);
        process.exit(1);
    }
}

runMigration();
