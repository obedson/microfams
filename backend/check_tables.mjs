import { supabase } from './src/utils/supabase.js';

async function checkTables() {
  try {
    console.log('Checking Supabase tables...\n');
    
    // Check if courses table exists and get its structure
    console.log('=== COURSES TABLE ===');
    try {
      const { data: courses, error: coursesError } = await supabase
        .from('courses')
        .select('*')
        .limit(1);
      
      if (coursesError) {
        console.log('Courses table error:', coursesError.message);
      } else {
        console.log('Courses table exists!');
        console.log('Sample data structure:', courses[0] || 'No data found');
        
        // Get all courses count
        const { count } = await supabase
          .from('courses')
          .select('*', { count: 'exact', head: true });
        console.log('Total courses:', count);
      }
    } catch (err) {
      console.log('Courses table does not exist or error:', err.message);
    }
    
    console.log('\n=== USER_PROGRESS TABLE ===');
    try {
      const { data: progress, error: progressError } = await supabase
        .from('user_progress')
        .select('*')
        .limit(1);
      
      if (progressError) {
        console.log('User progress table error:', progressError.message);
      } else {
        console.log('User progress table exists!');
        console.log('Sample data structure:', progress[0] || 'No data found');
        
        // Get all progress count
        const { count } = await supabase
          .from('user_progress')
          .select('*', { count: 'exact', head: true });
        console.log('Total progress records:', count);
      }
    } catch (err) {
      console.log('User progress table does not exist or error:', err.message);
    }
    
  } catch (error) {
    console.error('Error checking tables:', error);
  }
}

checkTables();
