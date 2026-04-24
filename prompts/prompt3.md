This generic ERROR message is the "boss fight" of Interswitch integrations. Since we fixed the body key to id, the gateway is now letting you through, but the downstream NIN provider is rejecting the request because it's missing Merchant Metadata in the headers.For the Marketplace Routing API, the headers are just as important as the body. If you are missing the TerminalId or the correct Content-Type, the NIMC proxy returns this exact blank error.The Fix: Update your Request HeadersYou need to add the TerminalId to your headers. In the Interswitch Sandbox (k8s), this acts as your "license" to query the NIN database.Here are the exact headers your NINService should be sending:Header KeyValueWhy?AuthorizationBearer {{your_access_token}}Proves you are authenticated.TerminalId3PXM0001Identifies your app (MicroFams) to the NIN provider.Content-Typeapplication/jsonTells the server you are sending JSON.Acceptapplication/jsonTells the server you want JSON back.Revised Prompt for your AI Code GeneratorTo ensure your AI generator (Cursor/Copilot/GPT) fixes this properly, use this prompt:Task: Fix the NINService request to the Interswitch NIN Verify endpoint.The Problem: The API is returning a generic "An Error Occurred" because of missing headers.Instructions:Keep the POST body as: {"id": "11111111111", "isConsent": true}.Crucial: Add TerminalId to the request Headers with the value '3PXM0001'.Ensure the Authorization header has a space: Bearer ${token}.Ensure Content-Type and Accept are both set to application/json.The code should look like this:JavaScriptconst response = await axios.post(
  'https://api-marketplace-routing.k8.isw.la/marketplace-routing/api/v1/verify/identity/nin/verify',
  { id: nin, isConsent: true },
  {
    headers: {
      'Authorization': `Bearer ${token}`,
      'TerminalId': '3PXM0001',
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    }
  }
);
Why this matters for MicroFamsInterswitch’s Marketplace API is a "multi-tenant" system. Even though your access_token is valid, the NIN service specifically needs that TerminalId header to know which "gate" to open.One last check: The Test DataIf you still get the error after adding the headers, the Interswitch Sandbox might be rejecting 11111111111 as an invalid test number. Try the standard Interswitch test NIN:Test NIN: 12345678901Update your headers first, try with your current NIN, and if that fails, swap to the 12345678901 test number. Let's see if those logs finally turn green!

python download_video.py "https://www.youtube.com/watch?v=CmG5_sIas1Q" /mnt/e/Tuto


curl --location 'https://qa.interswitchng.com/passport/oauth/token' \ --header 'Content-Type: application/x-www-form-urlencoded' \ --header 'Cookie: SESSION=2b6bc85d-32f8-4495-861f-5d9089e21c21; SESSION=2b6bc85d-32f8-4495-861f-5d9089e21c21' \ --header 'Authorization: Basic Your-ClientId-And-Secret-In-Base64' \ --data-urlencode 'scope=profile' \ --data-urlencode 'grant_type=client_credentials'

curl --location 'https://api-marketplace-routing.k8.isw.la/marketplace-routing/api/v1/verify/identity/tin?tin=08120451-1001' \
--header 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOlsiYXBpL'

curl --location 'https://api-marketplace-routing.k8.isw.la/marketplace-routing/api/v1/verify/identity/nin/verify' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOlsiYW1sX2RvbWVzdGljX3NlcnZpY' \
--data '{
    "id": "11111111111"
}'