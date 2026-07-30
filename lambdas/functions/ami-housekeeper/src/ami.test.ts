import {
  DeleteSnapshotCommand,
  DeregisterImageCommand,
  DescribeImagesCommand,
  DescribeLaunchTemplateVersionsCommand,
  DescribeLaunchTemplatesCommand,
  EC2Client,
  Image,
} from '@aws-sdk/client-ec2';
import { DescribeParametersCommand, DescribeParametersCommandOutput, SSMClient } from '@aws-sdk/client-ssm';
import { getParameters } from '@aws-github-runner/aws-ssm-util';
import { mockClient } from 'aws-sdk-client-mock';
import 'aws-sdk-client-mock-jest/vitest';

import {
  AmiCleanupOptions,
  amiCleanup,
  createMutationEc2Client,
  defaultAmiCleanupOptions,
  requestTimeoutWithinDeadline,
} from './ami';
import { describe, it, expect, beforeEach, vi } from 'vitest';

vi.mock('@aws-github-runner/aws-ssm-util');

process.env.AWS_REGION = 'eu-east-1';
const deleteAmisOlderThenDays = 30;
const date31DaysAgo = new Date(new Date().setDate(new Date().getDate() - (deleteAmisOlderThenDays + 1)));

const mockEC2Client = mockClient(EC2Client);
const mockSSMClient = mockClient(SSMClient);

const imagesInUseSsm: Image[] = [
  {
    ImageId: 'ami-00000000000000001',
    CreationDate: date31DaysAgo.toISOString(),
    BlockDeviceMappings: [
      {
        Ebs: {
          SnapshotId: 'snap-ssm0001',
        },
      },
    ],
  },
  {
    ImageId: 'ami-00000000000000002',
  },
];

const imagesInUseLaunchTemplates: Image[] = [
  {
    ImageId: 'ami-00000000000000003',
    CreationDate: date31DaysAgo.toISOString(),
  },
];

const imagesInUse: Image[] = [...imagesInUseSsm, ...imagesInUseLaunchTemplates];

const ssmParameters: DescribeParametersCommandOutput = {
  Parameters: [
    {
      Name: 'ami-id/ami-ssm0001',
      Type: 'String',
      Version: 1,
    },
    {
      Name: 'ami-id/ami-ssm0002',
      Type: 'String',
      Version: 1,
    },
  ],
  $metadata: {
    httpStatusCode: 200,
    requestId: '1234',
    extendedRequestId: '1234',
    cfId: undefined,
    attempts: 1,
    totalRetryDelay: 0,
  },
};

describe("delete AMI's", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mockEC2Client.reset();
    mockSSMClient.reset();

    mockSSMClient.on(DescribeParametersCommand).resolves(ssmParameters);
    vi.mocked(getParameters).mockResolvedValue(
      new Map([
        ['ami-id/ami-ssm0001', 'ami-00000000000000001'],
        ['ami-id/ami-ssm0002', 'ami-00000000000000002'],
      ]),
    );

    mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
      LaunchTemplates: [
        {
          LaunchTemplateId: 'lt-1234',
          LaunchTemplateName: 'lt-1234',
          DefaultVersionNumber: 1,
          LatestVersionNumber: 2,
        },
      ],
    });

    mockEC2Client
      .on(DescribeLaunchTemplateVersionsCommand, {
        LaunchTemplateId: 'lt-1234',
      })
      .resolves({
        LaunchTemplateVersions: [
          {
            LaunchTemplateId: 'lt-1234',
            LaunchTemplateName: 'lt-1234',
            VersionNumber: 2,
            LaunchTemplateData: {
              ImageId: 'ami-00000000000000003',
            },
          },
        ],
      });
  });

  mockEC2Client.on(DeregisterImageCommand).resolves({});
  mockEC2Client.on(DeleteSnapshotCommand).resolves({});

  it('should look up images in SSM, nothing to delete.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [],
    });

    await amiCleanup({ ssmParameterNames: ['*ami-id'] });
    expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
    expect(mockEC2Client).toHaveReceivedCommand(DescribeLaunchTemplatesCommand);
    expect(mockEC2Client).toHaveReceivedCommand(DescribeLaunchTemplateVersionsCommand);
    expect(mockSSMClient).toHaveReceivedCommand(DescribeParametersCommand);
    expect(getParameters).toHaveBeenCalledWith(
      ['ami-id/ami-ssm0001', 'ami-id/ami-ssm0002'],
      expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
    );
  });

  it('should NOT delete instances in use.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: imagesInUse,
    });

    // rely on defaults, instances imagesInSssm will be deleted as well
    await amiCleanup({
      ssmParameterNames: ['*ami-id'],
      minimumDaysOld: 0,
    });
    expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
  });

  it('Should rely on defaults if no options are passed.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [
        {
          ImageId: 'ami-00000000000000004',
          CreationDate: new Date().toISOString(),
        },
        {
          ImageId: 'ami-00000000000000005',
          CreationDate: date31DaysAgo.toISOString(),
        },
      ],
    });

    // force null values since json does not support undefined
    await amiCleanup({
      ssmParameterNames: null,
      minimumDaysOld: null,
      filters: null,
      launchTemplateNames: null,
      maxItems: null,
    } as unknown as AmiCleanupOptions);

    expect(mockSSMClient).not.toHaveReceivedCommand(DescribeParametersCommand);
    expect(mockEC2Client).toHaveReceivedCommandWith(DescribeLaunchTemplatesCommand, {
      LaunchTemplateNames: undefined,
    });
    expect(mockEC2Client).toHaveReceivedCommandWith(DescribeImagesCommand, {
      Filters: defaultAmiCleanupOptions.amiFilters,
      MaxResults: 1_000,
      NextToken: undefined,
      Owners: ['self'],
    });
    expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
      ImageId: 'ami-00000000000000005',
    });
  });

  it('should NOT delete instances in use, SSM not used.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: imagesInUse,
    });

    // rely on defaults, instances imagesInSssm will be deleted as well
    await amiCleanup({
      minimumDaysOld: 0,
    });

    // one images in imagesInUseSsm is not deleted since it has no creation date.
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 1);
    expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
      ImageId: 'ami-00000000000000001',
    });
    expect(mockEC2Client).toHaveReceivedCommandWith(DeleteSnapshotCommand, {
      SnapshotId: 'snap-ssm0001',
    });
  });

  it('should not call delete when no AMIs at all.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: undefined,
    });
    mockSSMClient.on(DescribeParametersCommand).resolves({
      Parameters: undefined,
    });
    mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
      LaunchTemplates: undefined,
    });

    await amiCleanup({ ssmParameterNames: ['*ami-id'] });
    expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
  });

  it('should filter delete AMIs not in use older then 30 days.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [
        ...imagesInUse,
        {
          ImageId: 'ami-00000000000000006',
          CreationDate: date31DaysAgo.toISOString(),
          BlockDeviceMappings: [
            {
              Ebs: {
                SnapshotId: 'snap-old0001',
              },
            },
          ],
        },
        {
          ImageId: 'ami-00000000000000007',
          CreationDate: date31DaysAgo.toISOString(),
        },
        {
          ImageId: 'ami-00000000000000008',
          CreationDate: new Date(new Date().setDate(new Date().getDate() - 1)).toISOString(),
          BlockDeviceMappings: [
            {
              Ebs: {
                SnapshotId: 'snap-notOld0001',
              },
            },
          ],
        },
      ],
    });

    await amiCleanup({
      minimumDaysOld: deleteAmisOlderThenDays,
      ssmParameterNames: ['*ami-id'],
    });
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 2);
    expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
      ImageId: 'ami-00000000000000006',
    });
    expect(mockEC2Client).toHaveReceivedCommandWith(DeleteSnapshotCommand, {
      SnapshotId: 'snap-old0001',
    });
    expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
      ImageId: 'ami-00000000000000007',
    });
    expect(mockEC2Client).not.toHaveReceivedCommandWith(DeregisterImageCommand, {
      ImageId: 'ami-00000000000000008',
    });
    expect(mockEC2Client).not.toHaveReceivedCommandWith(DeleteSnapshotCommand, {
      SnapshotId: 'snap-notOld0001',
    });

    expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 1);
  });

  it('should delete 1 AMIs AMI.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [
        {
          ImageId: 'ami-00000000000000006',
          CreationDate: date31DaysAgo.toISOString(),
        },
      ],
    });

    await amiCleanup({
      minimumDaysOld: deleteAmisOlderThenDays,
      ssmParameterNames: ['*ami-id'],
      maxItems: 1,
    });
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
    expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
      ImageId: 'ami-00000000000000006',
    });
    expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
  });

  it('should not delete a snapshot if ami deletion fails.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [
        ...imagesInUse,
        {
          ImageId: 'ami-00000000000000006',
          CreationDate: date31DaysAgo.toISOString(),
          BlockDeviceMappings: [
            {
              Ebs: {
                SnapshotId: 'snap-old0001',
              },
            },
          ],
        },
      ],
    });

    mockEC2Client.on(DeregisterImageCommand).rejects(
      Object.assign(new Error('AccessDenied'), {
        name: 'AccessDenied',
        $metadata: { httpStatusCode: 403 },
      }),
    );

    await expect(amiCleanup({ ssmParameterNames: ['*ami-id'] })).rejects.toThrow();
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
    expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
  });

  it('fails after a snapshot deletion fails.', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [
        ...imagesInUse,
        {
          ImageId: 'ami-00000000000000006',
          CreationDate: date31DaysAgo.toISOString(),
          BlockDeviceMappings: [
            {
              Ebs: {
                SnapshotId: 'snap-old0001',
              },
            },
          ],
        },
      ],
    });

    mockEC2Client.on(DeleteSnapshotCommand).rejects({});

    await expect(amiCleanup({ ssmParameterNames: ['*ami-id'] })).rejects.toThrow();
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
    expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 1);
  });

  it('should not delete AMIs referenced via resolve:ssm in launch templates.', async () => {
    // The only AMI owned by the account and older than the age threshold
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [
        {
          ImageId: 'ami-00000000000000009',
          CreationDate: date31DaysAgo.toISOString(),
        },
      ],
    });

    // Launch template that ultimately resolves to the AMI ID via
    // `resolve:ssm:`. Because the Lambda uses the EC2 `ResolveAlias` flag, the
    // ImageId that we receive from the API will already be resolved to the real
    // AMI ID.
    mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
      LaunchTemplates: [
        {
          LaunchTemplateId: 'lt-resolve',
          LaunchTemplateName: 'lt-resolve',
          DefaultVersionNumber: 1,
          LatestVersionNumber: 1,
        },
      ],
    });

    mockEC2Client
      .on(DescribeLaunchTemplateVersionsCommand, {
        LaunchTemplateId: 'lt-resolve',
      })
      .resolves({
        LaunchTemplateVersions: [
          {
            LaunchTemplateId: 'lt-resolve',
            LaunchTemplateName: 'lt-resolve',
            VersionNumber: 1,
            LaunchTemplateData: {
              ImageId: 'ami-00000000000000009', // resolved alias
            },
          },
        ],
      });

    // Run cleanup with same age threshold to force consideration of the AMI
    await amiCleanup({
      minimumDaysOld: 0,
      launchTemplateNames: ['lt-resolve'],
    });

    expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
  });

  it('uses ResolveAlias flag in launch template version calls', async () => {
    mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
      Images: [],
    });

    mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
      LaunchTemplates: [
        {
          LaunchTemplateId: 'lt-test',
          LaunchTemplateName: 'lt-test',
          DefaultVersionNumber: 1,
          LatestVersionNumber: 1,
        },
      ],
    });

    mockEC2Client.on(DescribeLaunchTemplateVersionsCommand).resolves({
      LaunchTemplateVersions: [
        {
          LaunchTemplateId: 'lt-test',
          LaunchTemplateName: 'lt-test',
          VersionNumber: 1,
          LaunchTemplateData: {
            ImageId: 'ami-0000000000000000a',
          },
        },
      ],
    });

    await amiCleanup({
      launchTemplateNames: ['lt-test'],
    });

    // Verify that ResolveAlias: true was passed to the command
    expect(mockEC2Client).toHaveReceivedCommandWith(DescribeLaunchTemplateVersionsCommand, {
      LaunchTemplateId: 'lt-test',
      Versions: ['$Default'],
      ResolveAlias: true,
    });
  });

  describe('SSM Parameter Handling', () => {
    beforeEach(() => {
      vi.resetAllMocks();
      mockEC2Client.reset();
      mockSSMClient.reset();

      // Default setup for launch templates (empty)
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
        LaunchTemplates: [],
      });
    });

    it('handles explicit SSM parameter names (ami_id with underscore)', async () => {
      // Setup AMI that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-0000000000000000b',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      vi.mocked(getParameters).mockResolvedValue(new Map([['/github-runner/config/ami_id', 'ami-0000000000000000b']]));

      await amiCleanup({
        minimumDaysOld: 0,
        ssmParameterNames: ['/github-runner/config/ami_id'],
      });

      // AMI should not be deleted because it's referenced in SSM
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(getParameters).toHaveBeenCalledWith(
        ['/github-runner/config/ami_id'],
        expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
      );
      expect(mockSSMClient).not.toHaveReceivedCommand(DescribeParametersCommand);
    });

    it('handles explicit SSM parameter names (ami-id with hyphen)', async () => {
      // AMI that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-0000000000000000c',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      vi.mocked(getParameters).mockResolvedValue(new Map([['/github-runner/config/ami-id', 'ami-0000000000000000c']]));

      await amiCleanup({
        minimumDaysOld: 0,
        ssmParameterNames: ['/github-runner/config/ami-id'],
      });

      // AMI should not be deleted because it's referenced in SSM
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(getParameters).toHaveBeenCalledWith(
        ['/github-runner/config/ami-id'],
        expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
      );
      expect(mockSSMClient).not.toHaveReceivedCommand(DescribeParametersCommand);
    });

    it('handles wildcard SSM parameter patterns (*ami-id)', async () => {
      // AMI that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-0000000000000000d',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      mockSSMClient.on(DescribeParametersCommand).resolves({
        Parameters: [
          {
            Name: '/some/path/ami-id',
            Type: 'String',
            Version: 1,
          },
        ],
      });

      vi.mocked(getParameters).mockResolvedValue(new Map([['/some/path/ami-id', 'ami-0000000000000000d']]));

      await amiCleanup({
        minimumDaysOld: 0,
        ssmParameterNames: ['*ami-id'],
      });

      // AMI should not be deleted because it's referenced in SSM
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockSSMClient).toHaveReceivedCommandWith(DescribeParametersCommand, {
        ParameterFilters: [{ Key: 'Name', Option: 'Contains', Values: ['ami-id'] }],
      });
      expect(getParameters).toHaveBeenCalledWith(
        ['/some/path/ami-id'],
        expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
      );
    });

    it('handles wildcard SSM parameter patterns (*ami_id)', async () => {
      // AMI that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-0000000000000000e',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      mockSSMClient.on(DescribeParametersCommand).resolves({
        Parameters: [
          {
            Name: '/github-runner/config/ami_id',
            Type: 'String',
            Version: 1,
          },
        ],
      });

      vi.mocked(getParameters).mockResolvedValue(new Map([['/github-runner/config/ami_id', 'ami-0000000000000000e']]));

      await amiCleanup({
        minimumDaysOld: 0,
        ssmParameterNames: ['*ami_id'],
      });

      // AMI should not be deleted because it's referenced in SSM
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockSSMClient).toHaveReceivedCommandWith(DescribeParametersCommand, {
        ParameterFilters: [{ Key: 'Name', Option: 'Contains', Values: ['ami_id'] }],
      });
      expect(getParameters).toHaveBeenCalledWith(
        ['/github-runner/config/ami_id'],
        expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
      );
    });

    it('handles mixed explicit names and wildcard patterns', async () => {
      // AMIs that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-0000000000000000f',
            CreationDate: date31DaysAgo.toISOString(),
          },
          {
            ImageId: 'ami-00000000000000010',
            CreationDate: date31DaysAgo.toISOString(),
          },
          {
            ImageId: 'ami-00000000000000011',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      vi.mocked(getParameters)
        .mockResolvedValueOnce(new Map([['/explicit/ami_id', 'ami-0000000000000000f']]))
        .mockResolvedValueOnce(new Map([['/discovered/ami-id', 'ami-00000000000000010']]));

      mockSSMClient.on(DescribeParametersCommand).resolves({
        Parameters: [
          {
            Name: '/discovered/ami-id',
            Type: 'String',
            Version: 1,
          },
        ],
      });

      await amiCleanup({
        minimumDaysOld: 0,
        ssmParameterNames: ['/explicit/ami_id', '*ami-id'],
      });

      // Only the unused AMI should be deleted
      expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
      expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
        ImageId: 'ami-00000000000000011',
      });

      expect(getParameters).toHaveBeenCalledWith(
        ['/explicit/ami_id'],
        expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
      );
      expect(mockSSMClient).toHaveReceivedCommandWith(DescribeParametersCommand, {
        ParameterFilters: [{ Key: 'Name', Option: 'Contains', Values: ['ami-id'] }],
      });
      expect(getParameters).toHaveBeenCalledWith(
        ['/discovered/ami-id'],
        expect.objectContaining({ client: expect.any(SSMClient), abortSignal: expect.any(AbortSignal) }),
      );
    });

    it('fails closed when an explicit SSM parameter cannot be read', async () => {
      // AMI that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-00000000000000012',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      vi.mocked(getParameters).mockRejectedValue(new Error('ParameterNotFound'));

      await expect(
        amiCleanup({
          minimumDaysOld: 0,
          ssmParameterNames: ['/nonexistent/ami_id'],
        }),
      ).rejects.toThrow();

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
    });

    it('fails closed when wildcard SSM discovery fails', async () => {
      // AMI that would be deleted if not referenced
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-00000000000000013',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      mockSSMClient.on(DescribeParametersCommand).rejects(new Error('AccessDenied'));

      await expect(
        amiCleanup({
          minimumDaysOld: 0,
          ssmParameterNames: ['*ami-id'],
        }),
      ).rejects.toThrow();

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
    });

    it('handles empty SSM parameter lists', async () => {
      // AMI that should be deleted
      mockEC2Client.on(DescribeImagesCommand, { Owners: ['self'] }).resolves({
        Images: [
          {
            ImageId: 'ami-00000000000000014',
            CreationDate: date31DaysAgo.toISOString(),
          },
        ],
      });

      await amiCleanup({
        minimumDaysOld: 0,
        ssmParameterNames: [],
      });

      // AMI should be deleted since no SSM parameters are checked
      expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
        ImageId: 'ami-00000000000000014',
      });
      expect(mockSSMClient).not.toHaveReceivedCommand(DescribeParametersCommand);
      expect(getParameters).not.toHaveBeenCalled();
    });
  });

  describe('release safety invariants', () => {
    beforeEach(() => {
      vi.useRealTimers();
      vi.resetAllMocks();
      mockEC2Client.reset();
      mockSSMClient.reset();
      vi.mocked(getParameters).mockResolvedValue(new Map());
    });

    it('disables automatic SDK retries for AMI mutations', async () => {
      const client = createMutationEc2Client();

      await expect(client.config.maxAttempts()).resolves.toBe(1);
      client.destroy();
    });

    it('uses an integer abort timeout with a fractional monotonic clock', () => {
      vi.spyOn(performance, 'now').mockReturnValue(1000.25);

      expect(requestTimeoutWithinDeadline(1005.75)).toBe(5);
    });

    it('fails closed when an explicitly requested launch template is missing', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-aaaaaaaaaaaaaaaaa',
            CreationDate: '2026-01-01T00:00:00.000Z',
          },
        ],
      });

      await expect(
        amiCleanup({
          launchTemplateNames: ['runner-amd64'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow(/launch template/i);

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('fails closed when an explicit SSM parameter contains a malformed AMI ID', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      vi.mocked(getParameters).mockResolvedValue(new Map([['/runner/active', 'ami-invalid']]));

      await expect(
        amiCleanup({
          ssmParameterNames: ['/runner/active'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow(/valid image id/i);

      expect(mockEC2Client).not.toHaveReceivedCommand(DescribeImagesCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('fails closed when an explicit SSM parameter is missing from the resolved map', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      vi.mocked(getParameters).mockResolvedValue(new Map());

      await expect(
        amiCleanup({
          ssmParameterNames: ['/runner/active'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow(/valid image id/i);

      expect(mockEC2Client).not.toHaveReceivedCommand(DescribeImagesCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('resolves explicit protection parameters sequentially in the supplied order', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({ Images: [] });
      const names = ['/runner/active', '/runner/previous', '/runner/recovery'];
      const values = new Map([
        [names[0], 'ami-aaaaaaaaaaaaaaaaa'],
        [names[1], 'ami-bbbbbbbbbbbbbbbbb'],
        [names[2], 'ami-ccccccccccccccccc'],
      ]);

      vi.mocked(getParameters).mockImplementation(async (requestedNames) => {
        expect(requestedNames).toHaveLength(1);
        const name = requestedNames[0];
        return new Map([[name, values.get(name)]]);
      });

      await amiCleanup({
        ssmParameterNames: names,
        minimumDaysOld: 0,
      });

      expect(vi.mocked(getParameters).mock.calls.map(([requestedNames]) => requestedNames)).toEqual(
        names.map((name) => [name]),
      );
    });

    it('fails wildcard SSM pagination before enumerating deletion candidates', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockSSMClient.on(DescribeParametersCommand).callsFake((input) => {
        if (input.NextToken === 'page-2') {
          throw new Error('wildcard page failed');
        }
        return {
          Parameters: [{ Name: '/runner/active' }],
          NextToken: 'page-2',
        };
      });

      await expect(
        amiCleanup({
          ssmParameterNames: ['*ami'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow('wildcard page failed');

      expect(mockEC2Client).not.toHaveReceivedCommand(DescribeImagesCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('fails closed when launch template alias resolution fails', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
        LaunchTemplates: [{ LaunchTemplateId: 'lt-release', LaunchTemplateName: 'runner-amd64' }],
      });
      mockEC2Client.on(DescribeLaunchTemplateVersionsCommand).rejects(new Error('AccessDenied'));
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-aaaaaaaaaaaaaaaaa',
            CreationDate: '2026-01-01T00:00:00.000Z',
          },
        ],
      });

      await expect(
        amiCleanup({
          launchTemplateNames: ['runner-amd64'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow('AccessDenied');

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('fails closed when a launch template resolves to a malformed AMI ID', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
        LaunchTemplates: [{ LaunchTemplateId: 'lt-release', LaunchTemplateName: 'runner-amd64' }],
      });
      mockEC2Client.on(DescribeLaunchTemplateVersionsCommand).resolves({
        LaunchTemplateVersions: [{ LaunchTemplateData: { ImageId: 'ami-invalid' } }],
      });

      await expect(
        amiCleanup({
          launchTemplateNames: ['runner-amd64'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow(/valid image id/i);

      expect(mockEC2Client).not.toHaveReceivedCommand(DescribeImagesCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('fails closed when a default launch template lookup returns multiple versions', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({
        LaunchTemplates: [{ LaunchTemplateId: 'lt-release', LaunchTemplateName: 'runner-amd64' }],
      });
      mockEC2Client.on(DescribeLaunchTemplateVersionsCommand).resolves({
        LaunchTemplateVersions: [
          { LaunchTemplateData: { ImageId: 'ami-aaaaaaaaaaaaaaaaa' } },
          { LaunchTemplateData: { ImageId: 'ami-bbbbbbbbbbbbbbbbb' } },
        ],
      });

      await expect(
        amiCleanup({
          launchTemplateNames: ['runner-amd64'],
          minimumDaysOld: 0,
        }),
      ).rejects.toThrow(/launch template/i);

      expect(mockEC2Client).not.toHaveReceivedCommand(DescribeImagesCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('fails launch template pagination before enumerating deletion candidates', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).callsFake((input) => {
        if (input.NextToken === 'page-2') {
          throw new Error('launch template page failed');
        }
        return {
          LaunchTemplates: [{ LaunchTemplateId: 'lt-release', LaunchTemplateName: 'runner-amd64' }],
          NextToken: 'page-2',
        };
      });

      await expect(amiCleanup({ minimumDaysOld: 0 })).rejects.toThrow('launch template page failed');

      expect(mockEC2Client).not.toHaveReceivedCommand(DescribeImagesCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
    });

    it('retains an image exactly on the strict age boundary', async () => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date('2026-07-30T12:00:00.000Z'));

      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-bbbbbbbbbbbbbbbbb',
            CreationDate: '2026-07-23T12:00:00.000Z',
          },
        ],
      });

      const cleanup = amiCleanup({ minimumDaysOld: 7 });
      await vi.advanceTimersByTimeAsync(100);
      await cleanup;

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      vi.useRealTimers();
    });

    it('uses one fixed evaluation time for every image', async () => {
      const evaluationTime = new Date('2026-07-30T12:00:00.000Z');
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-12121212121212121',
            CreationDate: '2026-07-23T12:00:00.000Z',
          },
          {
            ImageId: 'ami-34343434343434343',
            CreationDate: '2026-07-23T11:59:59.999Z',
          },
        ],
      });
      mockEC2Client.on(DeregisterImageCommand).resolves({});

      await amiCleanup({ minimumDaysOld: 7 }, evaluationTime);

      expect(mockEC2Client).not.toHaveReceivedCommandWith(DeregisterImageCommand, {
        ImageId: 'ami-12121212121212121',
      });
      expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
        ImageId: 'ami-34343434343434343',
      });
    });

    it('selects the same candidate in dry-run and live modes without dry-run mutations', async () => {
      const imageId = 'ami-56565656565656565';
      const evaluationTime = new Date('2026-07-30T12:00:00.000Z');
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: imageId,
            CreationDate: '2026-07-01T00:00:00.000Z',
            BlockDeviceMappings: [{ Ebs: { SnapshotId: 'snap-56565656565656565' } }],
          },
        ],
      });
      mockEC2Client.on(DeregisterImageCommand).resolves({});
      mockEC2Client.on(DeleteSnapshotCommand).resolves({});

      await amiCleanup({ dryRun: true, minimumDaysOld: 7 }, evaluationTime);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);

      await amiCleanup({ dryRun: false, minimumDaysOld: 7 }, evaluationTime);
      expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
        ImageId: imageId,
        DeleteAssociatedSnapshots: false,
      });
      expect(mockEC2Client).toHaveReceivedCommandWith(DeleteSnapshotCommand, {
        SnapshotId: 'snap-56565656565656565',
      });
    });

    it('does not exempt candidate, passed, or failed validation states from age cleanup', async () => {
      const images = ['candidate', 'passed', 'failed'].map((status, index) => ({
        ImageId: `ami-1000000000000000${index}`,
        CreationDate: '2026-01-01T00:00:00.000Z',
        Tags: [{ Key: 'ghr:validation_status', Value: status }],
      }));
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({ Images: images });
      mockEC2Client.on(DeregisterImageCommand).resolves({});

      await amiCleanup({ minimumDaysOld: 0 });

      expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 3);
      for (const image of images) {
        expect(mockEC2Client).toHaveReceivedCommandWith(DeregisterImageCommand, {
          ImageId: image.ImageId,
        });
      }
    });

    it('defers a mutation when the Lambda cannot finish the unknown-result window', async () => {
      const imageId = 'ami-78787878787878787';
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: imageId,
            CreationDate: '2026-01-01T00:00:00.000Z',
          },
        ],
      });

      await amiCleanup({ minimumDaysOld: 0 }, new Date(), () => 179_999);

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
    });

    it('waits for every snapshot deletion before returning', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-ccccccccccccccccc',
            CreationDate: '2026-01-01T00:00:00.000Z',
            BlockDeviceMappings: [
              { Ebs: { SnapshotId: 'snap-aaaaaaaaaaaaaaaaa' } },
              { Ebs: { SnapshotId: 'snap-bbbbbbbbbbbbbbbbb' } },
            ],
          },
        ],
      });
      mockEC2Client.on(DeregisterImageCommand).resolves({});

      let resolveFirst: (() => void) | undefined;
      let resolveSecond: (() => void) | undefined;
      mockEC2Client.on(DeleteSnapshotCommand, { SnapshotId: 'snap-aaaaaaaaaaaaaaaaa' }).callsFake(
        () =>
          new Promise((resolve) => {
            resolveFirst = () => resolve({});
          }),
      );
      mockEC2Client.on(DeleteSnapshotCommand, { SnapshotId: 'snap-bbbbbbbbbbbbbbbbb' }).callsFake(
        () =>
          new Promise((resolve) => {
            resolveSecond = () => resolve({});
          }),
      );

      let completed = false;
      const cleanup = amiCleanup({ minimumDaysOld: 0 }).then(() => {
        completed = true;
      });

      await vi.waitFor(() => {
        expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 2);
      });
      expect(completed).toBe(false);

      resolveFirst?.();
      await Promise.resolve();
      expect(completed).toBe(false);

      resolveSecond?.();
      await cleanup;
      expect(completed).toBe(true);
    });

    it.each(['InvalidSnapshot.InUse', 'InvalidSnapshot.NotFound'])(
      'classifies %s as a benign retained or skipped snapshot',
      async (name) => {
        mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
        mockEC2Client.on(DescribeImagesCommand).resolves({
          Images: [
            {
              ImageId: 'ami-ddddddddddddddddd',
              CreationDate: '2026-01-01T00:00:00.000Z',
              BlockDeviceMappings: [{ Ebs: { SnapshotId: 'snap-ccccccccccccccccc' } }],
            },
          ],
        });
        mockEC2Client.on(DeregisterImageCommand).resolves({});
        mockEC2Client.on(DeleteSnapshotCommand).rejects(Object.assign(new Error(name), { name }));

        await expect(amiCleanup({ minimumDaysOld: 0 })).resolves.toBeUndefined();
      },
    );

    it('continues deleting other snapshots after a benign snapshot result', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-20000000000000000',
            CreationDate: '2026-01-01T00:00:00.000Z',
            BlockDeviceMappings: [
              { Ebs: { SnapshotId: 'snap-20000000000000000' } },
              { Ebs: { SnapshotId: 'snap-20000000000000001' } },
            ],
          },
        ],
      });
      mockEC2Client.on(DeregisterImageCommand).resolves({});
      mockEC2Client
        .on(DeleteSnapshotCommand, { SnapshotId: 'snap-20000000000000000' })
        .rejects(Object.assign(new Error('in use'), { name: 'InvalidSnapshot.InUse' }));
      mockEC2Client.on(DeleteSnapshotCommand, { SnapshotId: 'snap-20000000000000001' }).resolves({});

      await expect(amiCleanup({ minimumDaysOld: 0 })).resolves.toBeUndefined();

      expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 2);
    });

    it('awaits every snapshot mutation before reporting multiple failures', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).resolves({
        Images: [
          {
            ImageId: 'ami-30000000000000000',
            CreationDate: '2026-01-01T00:00:00.000Z',
            BlockDeviceMappings: [
              { Ebs: { SnapshotId: 'snap-30000000000000000' } },
              { Ebs: { SnapshotId: 'snap-30000000000000001' } },
            ],
          },
        ],
      });
      mockEC2Client.on(DeregisterImageCommand).resolves({});
      mockEC2Client.on(DeleteSnapshotCommand).rejects(new Error('snapshot deletion failed'));

      await expect(amiCleanup({ minimumDaysOld: 0 })).rejects.toThrow(/Failed to delete/i);

      expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 2);
    });

    it('enumerates every candidate page before deleting any AMI', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).callsFake((input) => {
        if (input.NextToken === 'page-2') {
          return {
            Images: [{ ImageId: 'ami-22222222222222222', CreationDate: '2026-01-02T00:00:00.000Z' }],
          };
        }
        return {
          Images: [{ ImageId: 'ami-11111111111111111', CreationDate: '2026-01-01T00:00:00.000Z' }],
          NextToken: 'page-2',
        };
      });
      mockEC2Client.on(DeregisterImageCommand).resolves({});

      await amiCleanup({ minimumDaysOld: 0 });

      expect(mockEC2Client).toHaveReceivedCommandWith(DescribeImagesCommand, {
        Owners: ['self'],
        NextToken: 'page-2',
      });
      expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 2);
    });

    it('fails candidate pagination before deregistering any AMI', async () => {
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).callsFake((input) => {
        if (input.NextToken === 'page-2') {
          throw new Error('page failed');
        }
        return {
          Images: [{ ImageId: 'ami-11111111111111111', CreationDate: '2026-01-01T00:00:00.000Z' }],
          NextToken: 'page-2',
        };
      });

      await expect(amiCleanup({ minimumDaysOld: 0 })).rejects.toThrow('page failed');

      expect(mockEC2Client).not.toHaveReceivedCommand(DeregisterImageCommand);
      expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
    });

    it('does not retry an unknown deregistration and deletes snapshots only after read-back confirms it', async () => {
      const imageId = 'ami-eeeeeeeeeeeeeeeee';
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).callsFake((input) => {
        if (input.ImageIds) {
          return { Images: [] };
        }
        return {
          Images: [
            {
              ImageId: imageId,
              CreationDate: '2026-01-01T00:00:00.000Z',
              BlockDeviceMappings: [{ Ebs: { SnapshotId: 'snap-eeeeeeeeeeeeeeeee' } }],
            },
          ],
        };
      });
      mockEC2Client
        .on(DeregisterImageCommand)
        .rejects(Object.assign(new Error('socket timeout'), { name: 'TimeoutError' }));
      mockEC2Client.on(DeleteSnapshotCommand).resolves({});

      await amiCleanup({ minimumDaysOld: 0 });

      expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
      expect(mockEC2Client).toHaveReceivedCommandWith(DescribeImagesCommand, {
        ImageIds: [imageId],
        Owners: ['self'],
      });
      expect(mockEC2Client).toHaveReceivedCommandTimes(DeleteSnapshotCommand, 1);
    });

    it('leaves snapshots untouched when an unknown deregistration cannot be confirmed', async () => {
      vi.useFakeTimers();
      const imageId = 'ami-fffffffffffffffff';
      mockEC2Client.on(DescribeLaunchTemplatesCommand).resolves({ LaunchTemplates: [] });
      mockEC2Client.on(DescribeImagesCommand).callsFake((input) => {
        if (input.ImageIds) {
          return { Images: [{ ImageId: imageId, State: 'available' }] };
        }
        return {
          Images: [
            {
              ImageId: imageId,
              CreationDate: '2026-01-01T00:00:00.000Z',
              BlockDeviceMappings: [{ Ebs: { SnapshotId: 'snap-fffffffffffffffff' } }],
            },
          ],
        };
      });
      mockEC2Client
        .on(DeregisterImageCommand)
        .rejects(Object.assign(new Error('socket timeout'), { name: 'TimeoutError' }));

      const cleanup = expect(amiCleanup({ minimumDaysOld: 0 })).rejects.toThrow(/Failed to delete/i);
      await vi.advanceTimersByTimeAsync(121_000);

      await cleanup;
      expect(mockEC2Client).toHaveReceivedCommandTimes(DeregisterImageCommand, 1);
      expect(mockEC2Client).toHaveReceivedCommandWith(DescribeImagesCommand, {
        ImageIds: [imageId],
        Owners: ['self'],
      });
      expect(mockEC2Client).not.toHaveReceivedCommand(DeleteSnapshotCommand);
      vi.useRealTimers();
    });
  });
});
