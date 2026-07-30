import { logger } from '@aws-github-runner/aws-powertools-util';
import { Context } from 'aws-lambda';

import { AmiCleanupOptions, amiCleanup } from './ami';
import { handler } from './lambda';
import { describe, it, expect, beforeAll, vi } from 'vitest';

vi.mock('./ami');
vi.mock('@aws-github-runner/aws-powertools-util');

const amiCleanupOptions: AmiCleanupOptions = {
  minimumDaysOld: undefined,
  maxItems: undefined,
  amiFilters: undefined,
  launchTemplateNames: undefined,
  ssmParameterNames: undefined,
};

process.env.AMI_CLEANUP_OPTIONS = JSON.stringify(amiCleanupOptions);

const context: Context = {
  awsRequestId: '1',
  callbackWaitsForEmptyEventLoop: false,
  functionName: '',
  functionVersion: '',
  getRemainingTimeInMillis: () => 0,
  invokedFunctionArn: '',
  logGroupName: '',
  logStreamName: '',
  memoryLimitInMB: '',
  done: () => {
    return;
  },
  fail: () => {
    return;
  },
  succeed: () => {
    return;
  },
};

describe('Housekeeper ami', () => {
  beforeAll(() => {
    vi.resetAllMocks();
  });

  it('should not throw or log in error.', async () => {
    const mock = vi.mocked(amiCleanup);
    mock.mockImplementation(() => {
      return new Promise((resolve) => {
        resolve();
      });
    });
    await expect(handler(undefined, context)).resolves.not.toThrow();
    expect(mock).toHaveBeenCalledWith(amiCleanupOptions, expect.any(Date), expect.any(Function));
  });

  it('logs and rethrows cleanup errors so the invocation is marked failed.', async () => {
    const logSpy = vi.spyOn(logger, 'error');

    const error = new Error('An error.');
    const mock = vi.mocked(amiCleanup);
    mock.mockRejectedValue(error);
    await expect(handler(undefined, context)).rejects.toThrow(error);

    expect(logSpy).toHaveBeenCalledTimes(1);
  });
});
