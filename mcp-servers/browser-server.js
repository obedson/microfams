#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import puppeteer from 'puppeteer';

let browser = null;
let page = null;
const consoleLogs = [];
const networkRequests = [];

const server = new Server(
  {
    name: 'browser-devtools-server',
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
      name: 'open_browser',
      description: 'Open browser and navigate to URL',
      inputSchema: {
        type: 'object',
        properties: {
          url: {
            type: 'string',
            description: 'URL to navigate to',
          },
          headless: {
            type: 'boolean',
            description: 'Run in headless mode',
            default: false,
          },
        },
        required: ['url'],
      },
    },
    {
      name: 'get_console_logs',
      description: 'Get all console logs captured from the page',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'get_network_requests',
      description: 'Get all network requests captured',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'execute_script',
      description: 'Execute JavaScript in the browser page',
      inputSchema: {
        type: 'object',
        properties: {
          script: {
            type: 'string',
            description: 'JavaScript code to execute',
          },
        },
        required: ['script'],
      },
    },
    {
      name: 'get_page_errors',
      description: 'Get JavaScript errors from the page',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'screenshot',
      description: 'Take a screenshot of the current page',
      inputSchema: {
        type: 'object',
        properties: {
          fullPage: {
            type: 'boolean',
            description: 'Capture full page',
            default: false,
          },
        },
      },
    },
    {
      name: 'close_browser',
      description: 'Close the browser',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    if (name === 'open_browser') {
      if (browser) {
        await browser.close();
      }

      consoleLogs.length = 0;
      networkRequests.length = 0;

      browser = await puppeteer.launch({
        headless: args.headless || false,
        args: ['--no-sandbox', '--disable-setuid-sandbox'],
      });

      page = await browser.newPage();

      // Capture console logs
      page.on('console', (msg) => {
        consoleLogs.push({
          type: msg.type(),
          text: msg.text(),
          timestamp: new Date().toISOString(),
        });
      });

      // Capture network requests
      page.on('request', (request) => {
        networkRequests.push({
          url: request.url(),
          method: request.method(),
          type: request.resourceType(),
          timestamp: new Date().toISOString(),
        });
      });

      // Capture page errors
      page.on('pageerror', (error) => {
        consoleLogs.push({
          type: 'error',
          text: error.message,
          stack: error.stack,
          timestamp: new Date().toISOString(),
        });
      });

      await page.goto(args.url, { waitUntil: 'networkidle2' });

      return {
        content: [{
          type: 'text',
          text: `Browser opened and navigated to: ${args.url}`,
        }],
      };
    }

    if (name === 'get_console_logs') {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify(consoleLogs, null, 2),
        }],
      };
    }

    if (name === 'get_network_requests') {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify(networkRequests, null, 2),
        }],
      };
    }

    if (name === 'execute_script') {
      if (!page) {
        throw new Error('No browser page open. Use open_browser first.');
      }

      const result = await page.evaluate(args.script);

      return {
        content: [{
          type: 'text',
          text: JSON.stringify(result, null, 2),
        }],
      };
    }

    if (name === 'get_page_errors') {
      const errors = consoleLogs.filter(log => log.type === 'error');
      return {
        content: [{
          type: 'text',
          text: JSON.stringify(errors, null, 2),
        }],
      };
    }

    if (name === 'screenshot') {
      if (!page) {
        throw new Error('No browser page open. Use open_browser first.');
      }

      const screenshot = await page.screenshot({
        encoding: 'base64',
        fullPage: args.fullPage || false,
      });

      return {
        content: [{
          type: 'image',
          data: screenshot,
          mimeType: 'image/png',
        }],
      };
    }

    if (name === 'close_browser') {
      if (browser) {
        await browser.close();
        browser = null;
        page = null;
      }

      return {
        content: [{
          type: 'text',
          text: 'Browser closed',
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
