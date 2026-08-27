import { APIGatewayRequestAuthorizerEventV2 } from 'aws-lambda';

// GitHub signs the request body and sends `sha256=` plus the hex-encoded HMAC.
const SIGNATURE_PATTERN = /^sha256=[0-9a-f]{64}$/;
const HOOKSHOT_USER_AGENT_PATTERN = /^GitHub-Hookshot\//;

export interface GitHubOriginSignals {
  signaturePresent: boolean;
  signatureWellFormed: boolean;
  event?: string;
  deliveryId?: string;
  hookId?: string;
  hookInstallationTargetId?: string;
  hookInstallationTargetType?: string;
  userAgentIsHookshot: boolean;
  sourceIp?: string;
}

/**
 * Describes the GitHub-origin signals an API Gateway authorizer is able to see.
 *
 * An authorizer payload never carries the request body, so the signature can
 * only be checked for shape here, not verified. Verification happens in the
 * webhook lambda, which is the only place that has the body.
 *
 * Total by construction: it must not throw on a malformed event, because the
 * authorizer that calls it has to answer every request.
 */
export function describeGitHubOrigin(event: Partial<APIGatewayRequestAuthorizerEventV2>): GitHubOriginSignals {
  const headers = lowerCaseKeys(event.headers);
  const signature = headers['x-hub-signature-256'];

  return {
    signaturePresent: !!signature,
    signatureWellFormed: SIGNATURE_PATTERN.test(signature ?? ''),
    event: headers['x-github-event'],
    deliveryId: headers['x-github-delivery'],
    hookId: headers['x-github-hook-id'],
    hookInstallationTargetId: headers['x-github-hook-installation-target-id'],
    hookInstallationTargetType: headers['x-github-hook-installation-target-type'],
    userAgentIsHookshot: HOOKSHOT_USER_AGENT_PATTERN.test(headers['user-agent'] ?? ''),
    sourceIp: event.requestContext?.http?.sourceIp,
  };
}

// API Gateway lower cases header names, GitHub does not. Normalise either way.
function lowerCaseKeys(headers?: Record<string, string | undefined>): Record<string, string | undefined> {
  const normalized: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(headers ?? {})) {
    normalized[key.toLowerCase()] = value;
  }
  return normalized;
}
