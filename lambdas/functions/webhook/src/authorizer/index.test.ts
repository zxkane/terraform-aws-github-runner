import { APIGatewayRequestAuthorizerEventV2 } from 'aws-lambda';
import { describe, it, expect } from 'vitest';

import { describeGitHubOrigin } from '.';

const signature = `sha256=${'a'.repeat(64)}`;

function authorizerEvent(
  headers: Record<string, string | undefined>,
  sourceIp = '140.82.115.1',
): Partial<APIGatewayRequestAuthorizerEventV2> {
  return {
    headers,
    requestContext: { http: { sourceIp } },
  } as unknown as Partial<APIGatewayRequestAuthorizerEventV2>;
}

describe('describeGitHubOrigin', () => {
  it('reports every signal of a genuine GitHub delivery', () => {
    const signals = describeGitHubOrigin(
      authorizerEvent({
        'X-Hub-Signature-256': signature,
        'X-GitHub-Event': 'workflow_job',
        'X-GitHub-Delivery': 'ec4a1a30-1234-11ef-9b7e-000000000000',
        'X-GitHub-Hook-ID': '1234',
        'X-GitHub-Hook-Installation-Target-ID': '567890',
        'X-GitHub-Hook-Installation-Target-Type': 'integration',
        'User-Agent': 'GitHub-Hookshot/abc123',
      }),
    );

    expect(signals).toEqual({
      signaturePresent: true,
      signatureWellFormed: true,
      event: 'workflow_job',
      deliveryId: 'ec4a1a30-1234-11ef-9b7e-000000000000',
      hookId: '1234',
      hookInstallationTargetId: '567890',
      hookInstallationTargetType: 'integration',
      userAgentIsHookshot: true,
      sourceIp: '140.82.115.1',
    });
  });

  it('normalises header casing', () => {
    const signals = describeGitHubOrigin(
      authorizerEvent({ 'x-hub-signature-256': signature, 'x-github-event': 'ping' }),
    );

    expect(signals.signatureWellFormed).toBe(true);
    expect(signals.event).toBe('ping');
  });

  it.each([
    ['missing', undefined],
    ['empty', ''],
    ['unprefixed', 'a'.repeat(64)],
    ['truncated', `sha256=${'a'.repeat(63)}`],
    ['uppercase hex', `sha256=${'A'.repeat(64)}`],
    ['sha1', `sha1=${'a'.repeat(40)}`],
  ])('flags a %s signature as not well formed', (_name, value) => {
    const signals = describeGitHubOrigin(authorizerEvent({ 'x-hub-signature-256': value }));

    expect(signals.signatureWellFormed).toBe(false);
  });

  it('reports a non GitHub user agent', () => {
    const signals = describeGitHubOrigin(authorizerEvent({ 'user-agent': 'curl/8.5.0' }));

    expect(signals.userAgentIsHookshot).toBe(false);
  });

  it('does not throw on an event without headers or request context', () => {
    const signals = describeGitHubOrigin({});

    expect(signals).toEqual({
      signaturePresent: false,
      signatureWellFormed: false,
      event: undefined,
      deliveryId: undefined,
      hookId: undefined,
      hookInstallationTargetId: undefined,
      hookInstallationTargetType: undefined,
      userAgentIsHookshot: false,
      sourceIp: undefined,
    });
  });
});
