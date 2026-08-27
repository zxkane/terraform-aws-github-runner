import middy from '@middy/core';
import { logger, setContext, captureLambdaHandler, tracer } from '@aws-github-runner/aws-powertools-util';
import {
  APIGatewayEvent,
  APIGatewayRequestAuthorizerEventV2,
  APIGatewaySimpleAuthorizerResult,
  Context,
} from 'aws-lambda';

import { describeGitHubOrigin } from './authorizer';
import { publishForRunners, publishOnEventBridge } from './webhook';
import { IncomingHttpHeaders } from 'http';
import ValidationError from './ValidationError';
import { EventWrapper } from './types';
import { WorkflowJobEvent } from '@octokit/webhooks-types';
import { ConfigDispatcher, ConfigWebhook, ConfigWebhookEventBridge } from './ConfigLoader';
import { dispatch } from './runners/dispatch';

export interface Response {
  statusCode: number;
  body: string;
}

middy(directWebhook).use(captureLambdaHandler(tracer));

export async function directWebhook(event: APIGatewayEvent, context: Context): Promise<Response> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  let result: Response;
  try {
    const config: ConfigWebhook = await ConfigWebhook.load();
    result = await publishForRunners(headersToLowerCase(event.headers), event.body as string, config);
  } catch (e) {
    logger.error(`Failed to handle webhook event`, { error: e });
    if (e instanceof ValidationError) {
      result = {
        statusCode: e.statusCode,
        body: e.message,
      };
    } else {
      result = {
        statusCode: 500,
        body: 'Check the Lambda logs for the error details.',
      };
    }
  }
  return result;
}

export async function eventBridgeWebhook(event: APIGatewayEvent, context: Context): Promise<Response> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  let result: Response;
  try {
    const config: ConfigWebhookEventBridge = await ConfigWebhookEventBridge.load();
    result = await publishOnEventBridge(headersToLowerCase(event.headers), event.body as string, config);
  } catch (e) {
    logger.error(`Failed to handle webhook event`, { error: e });
    if (e instanceof ValidationError) {
      result = {
        statusCode: e.statusCode,
        body: e.message,
      };
    } else {
      result = {
        statusCode: 500,
        body: 'Check the Lambda logs for the error details.',
      };
    }
  }
  return result;
}

/**
 * Authorizer for the webhook route, present to satisfy the API Gateway
 * authorization control. It always allows.
 *
 * A Lambda authorizer cannot verify the GitHub HMAC: neither the 1.0 nor the
 * 2.0 authorizer payload format carries the request body, and the signature is
 * computed over that body. Verification therefore stays in the webhook lambda
 * (`verifySignature` in ./webhook), which rejects an invalid signature with a
 * 401. Do not drop that check on the assumption the gateway performs it.
 *
 * The authorizer is attached with no identity sources, so API Gateway invokes
 * it for every request rather than rejecting a request that lacks a given
 * header. Its decision is constant and it calls nothing, so it has no failure
 * mode of its own; the origin signals are logged only to make the request
 * population visible before anyone considers tightening the gateway.
 */
export async function githubWebhookAuthorizer(
  event: APIGatewayRequestAuthorizerEventV2,
  context: Context,
): Promise<APIGatewaySimpleAuthorizerResult> {
  // Never throw. An authorizer error reaches GitHub as a failed delivery, and
  // GitHub does not redeliver, so a lost `workflow_job` event leaves the job
  // queued with no runner.
  try {
    setContext(context, 'lambda.ts');
    logger.logEventIfEnabled(event);
    logger.info('GitHub webhook request reached the authorizer', { github: describeGitHubOrigin(event) });
  } catch {
    // Observability is best effort, the authorization decision is constant.
  }
  return { isAuthorized: true };
}

export async function dispatchToRunners(event: EventWrapper<WorkflowJobEvent>, context: Context): Promise<void> {
  setContext(context, 'lambda.ts');
  logger.logEventIfEnabled(event);

  const eventType = event['detail-type'];
  if (eventType != 'workflow_job') {
    logger.debug('Wrong event type received. Unable to process event', { event });
    throw new Error('Incorrect Event detail-type only workflow_job is accepted');
  }

  try {
    const config: ConfigDispatcher = await ConfigDispatcher.load();
    await dispatch(event.detail, eventType, config);
  } catch (e) {
    logger.error(`Failed to handle webhook event`, { error: e });
    throw e;
  }
}

// ensure header keys lower case since github headers can contain capitals.
function headersToLowerCase(headers: IncomingHttpHeaders): IncomingHttpHeaders {
  for (const key in headers) {
    headers[key.toLowerCase()] = headers[key];
  }
  return headers;
}
