// CloudFront Function (viewer-request) — Basic Auth for the admin user guide.
// Credentials are baked in at deploy time via templatefile().
var CREDENTIALS = "${credentials_b64}";

function handler(event) {
  var request = event.request;
  var headers = request.headers;
  var auth = headers.authorization;

  if (auth && auth.value === "Basic " + CREDENTIALS) {
    return request;
  }

  return {
    statusCode: 401,
    statusDescription: "Unauthorized",
    headers: {
      "www-authenticate": { value: 'Basic realm="Creatura Admin Guide"' }
    }
  };
}
