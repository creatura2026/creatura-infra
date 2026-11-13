// CloudFront Function (viewer-request) attached to the default cache behavior.
// Both apps use client-side routing: a URL such as /catalogue or /admin/echanges
// is not a file in S3, so it must be answered with the matching index.html.
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  var lastSegment = uri.substring(uri.lastIndexOf('/') + 1);

  // Real files (sw.js, manifest.webmanifest, favicon.ico, icons...) are served as-is.
  if (lastSegment.indexOf('.') !== -1) {
    return request;
  }

  if (uri === '/admin' || uri.indexOf('/admin/') === 0) {
    request.uri = '/admin/index.html';
  } else {
    request.uri = '/index.html';
  }

  return request;
}
