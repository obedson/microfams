#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_SERVICE_KEY;

if (!supabaseUrl || !supabaseKey) {
  console.error('Error: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set');
  process.exit(1);
}

// Lazy initialization - only create client when needed
let supabase = null;
function getSupabase() {
  if (!supabase) {
    supabase = createClient(supabaseUrl, supabaseKey);
  }
  return supabase;
}

const server = new Server(
  {
    name: 'supabase-mcp-server',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'list_tables',
      description: 'List all tables in the public schema',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'get_table_data',
      description: 'Get sample data from a table (limited to 10 rows)',
      inputSchema: {
        type: 'object',
        properties: {
          table_name: {
            type: 'string',
            description: 'Name of the table',
          },
          limit: {
            type: 'number',
            description: 'Number of rows to return (max 50)',
            default: 10,
          },
        },
        required: ['table_name'],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    if (name === 'list_tables') {
      const supabase = getSupabase();
      const { data, error } = await supabase
        .from('information_schema.tables')
        .select('table_name')
        .eq('table_schema', 'public')
        .order('table_name');

      if (error) throw error;

      const tableNames = data.map(t => t.table_name).join('\n');
      return {
        content: [{
          type: 'text',
          text: `Tables in database:\n${tableNames}`,
        }],
      };
    }

    if (name === 'get_table_data') {
      const limit = Math.min(args.limit || 10, 50);
      const supabase = getSupabase();
      
      const { data, error } = await supabase
        .from(args.table_name)
        .select('*')
        .limit(limit);

      if (error) throw error;

      return {
        content: [{
          type: 'text',
          text: JSON.stringify(data, null, 2),
        }],
      };
    }

    throw new Error(`Unknown tool: ${name}`);
  } catch (error) {
    return {
      content: [{
        type: 'text',
        text: `Error: ${error.message}`,
      }],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error('Server error:', error);
  process.exit(1);
});
