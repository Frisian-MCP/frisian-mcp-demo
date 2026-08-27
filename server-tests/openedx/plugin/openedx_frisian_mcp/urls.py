"""
URL patterns injected into the LMS by :class:`OpenedxFrisianMcpConfig`.

Three mounts, and the split matters:

  /mcp/                the MCP endpoint itself
  /mcp/oauth/          the OAuth authorize/token/consent views
  /.well-known/        RFC 9728 protected-resource and RFC 8414 authorization
                       server metadata

The well-known documents MUST be at the site root, not under /mcp/. A
spec-compliant MCP client that receives a 401 walks
`/.well-known/oauth-protected-resource/<path>` then
`/.well-known/oauth-authorization-server` to find the authorization endpoint.
Mounting them anywhere else leaves the client with no way to discover OAuth,
and it falls back to guessing `/authorize` at the root — which is not where
the package mounts it. The connector then dead-ends on an HTML 404.
"""

from django.urls import include, path, re_path

urlpatterns = [
    re_path(r"^mcp/?", include("frisian_mcp.urls")),
    path("mcp/oauth/", include("frisian_mcp.contrib.oauth.urls")),
    path(".well-known/", include("frisian_mcp.contrib.oauth.wellknown_urls")),
]
