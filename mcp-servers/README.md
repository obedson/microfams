# MCP Servers for Farmle

This directory contains Model Context Protocol (MCP) servers that give Kiro AI access to:
1. **Supabase Database** - Query and inspect database
2. **Browser DevTools** - Debug frontend in real-time

## Installation

```bash
cd mcp-servers
npm install
```

## Configuration

### 1. Get Your Supabase Credentials

1. Go to your Supabase project dashboard
2. Navigate to **Settings** → **API**
3. Copy:
   - **Project URL** (SUPABASE_URL)
   - **service_role key** (SUPABASE_SERVICE_KEY) - ⚠️ Keep this secret!

### 2. Configure Kiro CLI

Find your Kiro CLI config file location:
```bash
kiro-cli --help
```

Edit the config file (usually `~/.kiro/config.json` or similar) and add:

```json
{
  "mcpServers": {
    "supabase": {
      "command": "node",
      "args": ["/absolute/path/to/microfarm/mcp-servers/supabase-server.js"],
      "env": {
        "SUPABASE_URL": "https://your-project.supabase.co",
        "SUPABASE_SERVICE_KEY": "your-service-role-key-here"
      }
    },
    "browser": {
      "command": "node",
      "args": ["/absolute/path/to/microfarm/mcp-servers/browser-server.js"]
    }
  }
}
```

**Important:** Replace `/absolute/path/to/microfarm` with your actual project path.

### 3. Restart Kiro CLI

Close and reopen Kiro CLI to load the MCP servers.

## Usage

Once configured, you can ask Kiro:

### Database Queries
- "List all tables in the database"
- "Describe the bookings table"
- "Show me 5 rows from the users table"
- "Query: SELECT * FROM bookings WHERE status = 'confirmed' LIMIT 10"

### Browser Debugging
- "Open http://localhost:3000 in the browser"
- "Get console logs from the page"
- "Show me network requests"
- "Execute this script: document.querySelector('.error').textContent"
- "Take a screenshot"
- "Get page errors"

## Available Tools

### Supabase Server
- `list_tables` - List all database tables
- `describe_table` - Get table schema
- `get_table_data` - Get sample data (max 50 rows)
- `query_database` - Execute SELECT queries

### Browser Server
- `open_browser` - Open and navigate to URL
- `get_console_logs` - Get all console logs
- `get_network_requests` - Get network activity
- `execute_script` - Run JavaScript in page
- `get_page_errors` - Get JavaScript errors
- `screenshot` - Take screenshot
- `close_browser` - Close browser

## Security Notes

⚠️ **Important:**
- The `service_role` key has full database access
- Never commit credentials to git
- Only use SELECT queries (INSERT/UPDATE/DELETE blocked for safety)
- Keep your config file secure

## Troubleshooting

### "Module not found" error
```bash
cd mcp-servers
npm install
```

### "SUPABASE_URL not set" error
Check your Kiro CLI config file has the correct environment variables.

### Browser won't open
Make sure you have Chrome/Chromium installed. Puppeteer will download it automatically on first run.

### Can't find config file
Run `kiro-cli --help` to see the config file location, or check:
- `~/.kiro/config.json`
- `~/.config/kiro/config.json`
- Project root `.kiro/config.json`

## Example Session

```
You: "List all tables in my database"
Kiro: [Uses supabase MCP server to list tables]

You: "Show me the structure of the bookings table"
Kiro: [Uses describe_table tool]

You: "Open localhost:3000 in browser and check for errors"
Kiro: [Opens browser, captures console logs and errors]
```

## Development

To test the servers manually:

```bash
# Test Supabase server
SUPABASE_URL=your-url SUPABASE_SERVICE_KEY=your-key node supabase-server.js

# Test browser server
node browser-server.js
```

## License

Part of the Farmle project.
