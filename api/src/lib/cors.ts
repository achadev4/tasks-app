export function corsHeaders(request: { headers: Headers }): Record<string, string> {
  const origin = request.headers.get("origin") ?? "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET,POST,PATCH,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Max-Age": "86400",
  };
}

export function mergeCors(
  request: { headers: Headers },
  body: Record<string, string>
): Record<string, string> {
  return { ...corsHeaders(request), ...body };
}
