Gemini said
To get an AI code generator (like Cursor, GitHub Copilot, or GPT-4) to build this correctly for MicroFams, you need to define the Authentication and the Identity Verification as a connected flow.

Copy and paste the following prompt. It is structured to ensure the AI understands the Interswitch Passport v2 security requirements and the specific Marketplace Routing API.

Prompt for AI Code Generator
Task: Implement a two-step identity verification flow using the Interswitch Passport and Marketplace Routing APIs in [INSERT YOUR LANGUAGE, e.g., Node.js/Python].

Step 1: Generate OAuth2 Access Token

Endpoint: https://passport-v2.k8.isw.la/passport/oauth/token

Method: POST

Authentication: Use Basic Auth with CLIENT_ID and CLIENT_SECRET.

Headers: Content-Type: application/x-www-form-urlencoded

Body (URL Encoded): * grant_type: client_credentials

scope: profile

Expected Output: Extract the access_token from the JSON response to use in the next step.

Step 2: Verify NIN Details

Endpoint: https://api-marketplace-routing.k8.isw.la/marketplace-routing/api/v1/verify/identity/nin/verify

Method: POST

Authentication: Use Bearer Token (the access_token from Step 1).

Headers: Content-Type: application/json

Body (JSON):

JSON
{
  "idNumber": "[USER_NIN_INPUT]",
  "isConsent": true
}
Requirement: Handle the response by extracting the firstName, lastName, and the Base64 image string. Ensure there is a clear error handling block if the NIN is not found or the token is expired.

Key Technical Details for Your Implementation
When the AI generates the code, keep an eye on these two "gotchas" that often cause bugs:

The Token Format:
In the second call, the header must be exactly Authorization: Bearer <token>. If the AI forgets the space between "Bearer" and the token, the Interswitch server will return a 401 Unauthorized.

Payload Type Mismatch:

Step 1 uses URL Encoded Form Data (application/x-www-form-urlencoded).

Step 2 uses JSON (application/json).
Most AI generators might try to use JSON for both—make sure it keeps them distinct as specified in the prompt.

The isConsent Flag:
Interswitch will reject any NIN query that doesn't explicitly include "isConsent": true. I included this in the prompt so the AI doesn't leave it out.