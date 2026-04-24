#!/bin/bash

# Add .js extensions to relative imports that don't already have them
find backend/src -name "*.ts" -type f -exec sed -i -E "s|from '(\.\./[^']+)'|from '\1.js'|g; s|from '(\./[^']+)'|from '\1.js'|g; s|\.js\.js|.js|g" {} \;

echo "Fixed imports"
