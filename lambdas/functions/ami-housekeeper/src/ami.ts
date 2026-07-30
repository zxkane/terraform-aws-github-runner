import {
  DeleteSnapshotCommand,
  DeregisterImageCommand,
  DescribeImagesCommand,
  DescribeLaunchTemplateVersionsCommand,
  DescribeLaunchTemplatesCommand,
  EC2Client,
  Filter,
  Image,
} from '@aws-sdk/client-ec2';
import { SSMClient, DescribeParametersCommand } from '@aws-sdk/client-ssm';
import { createChildLogger } from '@aws-github-runner/aws-powertools-util';
import { getTracedAWSV3Client } from '@aws-github-runner/aws-powertools-util';
import { getParameters } from '@aws-github-runner/aws-ssm-util';
import { NodeHttpHandler } from '@smithy/node-http-handler';

const logger = createChildLogger('ami');
const DEREGISTRATION_CONFIRMATION_TIMEOUT_MS = 120_000;
const DEREGISTRATION_CONFIRMATION_POLL_MS = 3_000;
const AWS_CONNECTION_TIMEOUT_MS = 5_000;
const AWS_REQUEST_TIMEOUT_MS = 15_000;
const MUTATION_MINIMUM_REMAINING_MS = DEREGISTRATION_CONFIRMATION_TIMEOUT_MS + 2 * AWS_REQUEST_TIMEOUT_MS + 30_000;
const AMI_ID_PATTERN = /^ami-(?:[0-9a-f]{8}|[0-9a-f]{17})$/;

export interface AmiCleanupOptions {
  minimumDaysOld?: number;
  maxItems?: number;
  amiFilters?: Filter[];
  launchTemplateNames?: string[];
  ssmParameterNames?: string[];
  dryRun?: boolean;
}

interface AmiCleanupOptionsInternal extends AmiCleanupOptions {
  minimumDaysOld: number;
  amiFilters: Filter[];
  dryRun: boolean;
}

export const defaultAmiCleanupOptions: AmiCleanupOptionsInternal = {
  minimumDaysOld: 30,
  maxItems: undefined,
  amiFilters: [
    {
      Name: 'state',
      Values: ['available'],
    },
    {
      Name: 'image-type',
      Values: ['machine'],
    },
  ],
  launchTemplateNames: undefined,
  ssmParameterNames: undefined,
  dryRun: false,
};

function applyDefaults(options: AmiCleanupOptions): AmiCleanupOptionsInternal {
  return {
    minimumDaysOld: options.minimumDaysOld ?? defaultAmiCleanupOptions.minimumDaysOld,
    maxItems: options.maxItems ?? defaultAmiCleanupOptions.maxItems,
    amiFilters: options.amiFilters ?? defaultAmiCleanupOptions.amiFilters,
    launchTemplateNames: options.launchTemplateNames ?? defaultAmiCleanupOptions.launchTemplateNames,
    ssmParameterNames: options.ssmParameterNames ?? defaultAmiCleanupOptions.ssmParameterNames,
    dryRun: options.dryRun ?? defaultAmiCleanupOptions.dryRun,
  };
}

function createMutationEc2Client(): EC2Client {
  // An unknown DeregisterImage result must be reconciled by DescribeImages,
  // never by an automatic SDK retry of the mutation.
  return getTracedAWSV3Client(
    new EC2Client({
      maxAttempts: 1,
      requestHandler: new NodeHttpHandler({
        connectionTimeout: AWS_CONNECTION_TIMEOUT_MS,
        requestTimeout: AWS_REQUEST_TIMEOUT_MS,
      }),
    }),
  );
}

function createReadEc2Client(): EC2Client {
  return getTracedAWSV3Client(
    new EC2Client({
      requestHandler: new NodeHttpHandler({
        connectionTimeout: AWS_CONNECTION_TIMEOUT_MS,
        requestTimeout: AWS_REQUEST_TIMEOUT_MS,
      }),
    }),
  );
}

function createReadSsmClient(): SSMClient {
  return getTracedAWSV3Client(
    new SSMClient({
      requestHandler: new NodeHttpHandler({
        connectionTimeout: AWS_CONNECTION_TIMEOUT_MS,
        requestTimeout: AWS_REQUEST_TIMEOUT_MS,
      }),
    }),
  );
}

function readAbortSignal(): AbortSignal {
  return AbortSignal.timeout(AWS_REQUEST_TIMEOUT_MS);
}

function isAmiId(value: unknown): value is string {
  return typeof value === 'string' && AMI_ID_PATTERN.test(value);
}

function requestTimeoutWithinDeadline(deadline: number): number {
  return Math.max(1, Math.floor(Math.min(AWS_REQUEST_TIMEOUT_MS, deadline - performance.now())));
}

/**
 * Clean up old AMIs that are not actively used.
 *
 * 1. Identify AMIs that are not referenced in Launch Templates or SSM
 *    parameters
 * 2. Keep AMIs newer than the specified age threshold
 * 3. Delete the remaining AMIs and their associated snapshots
 *
 * @param options Configuration for the cleanup process
 */
async function amiCleanup(
  options: AmiCleanupOptions,
  evaluationTime = new Date(),
  getRemainingTimeInMillis: () => number = () => Number.POSITIVE_INFINITY,
): Promise<void> {
  const mergedOptions = applyDefaults(options);
  logger.info(`Cleaning up non used AMIs older then ${mergedOptions.minimumDaysOld} days`);
  logger.info(`Using fixed AMI cleanup evaluation time ${evaluationTime.toISOString()}`);
  logger.debug('Using the following options', {
    options: mergedOptions,
    evaluationTime: evaluationTime.toISOString(),
  });

  // Identify AMIs that are safe to delete (not referenced anywhere)
  const amisNotInUse = await getAmisNotInUse(mergedOptions);

  // Delete each AMI with a small delay to avoid overwhelming the API
  const errors: unknown[] = [];
  for (const image of amisNotInUse) {
    await new Promise((resolve) => setTimeout(resolve, 100)); // Rate limiting
    if (!mergedOptions.dryRun && getRemainingTimeInMillis() < MUTATION_MINIMUM_REMAINING_MS) {
      logger.warn(
        `Deferring AMI deletion because less than ${MUTATION_MINIMUM_REMAINING_MS}ms remains in this invocation`,
      );
      break;
    }
    try {
      await deleteAmi(image, mergedOptions, evaluationTime);
    } catch (error) {
      errors.push(error);
    }
  }

  if (errors.length > 0) {
    throw new AggregateError(errors, `Failed to delete ${errors.length} AMI resource set(s)`);
  }
}

/**
 * Filter out AMIs that are currently in use.
 *
 * 1. Discover AMIs referenced in SSM parameters (both explicit and wildcard
 *    patterns)
 * 2. Discover AMIs referenced in Launch Templates
 * 3. Get all account-owned AMIs matching the provided filters
 * 4. Exclude AMIs from (1) and (2)
 *
 * @param options Configuration for the cleanup process
 * @returns Array of AMI objects that are not referenced and eligible for
 *          deletion
 */
async function getAmisNotInUse(options: AmiCleanupOptions): Promise<Array<Image & { ImageId: string }>> {
  // Concurrently discover AMIs that are actively referenced and should be preserved
  const amiIdsInSSM = await getAmisReferedInSSM(options);
  const amiIdsInTemplates = await getAmiInLatestTemplates(options);

  // Fetch all account-owned AMIs that match the specified filters
  const ec2Client = createReadEc2Client();
  logger.debug('Getting all AMIs from ec2 with filters', { filters: options.amiFilters });
  const images: Image[] = [];
  let nextToken: string | undefined;
  do {
    const amiEc2 = await ec2Client.send(
      new DescribeImagesCommand({
        Owners: ['self'], // Only consider AMIs owned by this account
        MaxResults: options.maxItems ?? 1_000,
        Filters: options.amiFilters, // Apply additional filters (e.g., state=available)
        NextToken: nextToken,
      }),
      { abortSignal: readAbortSignal() },
    );
    images.push(...(amiEc2.Images ?? []));
    logger.debug('Found an AMI candidate page', { amiEc2 });

    if (options.maxItems !== undefined && images.length >= options.maxItems) {
      break;
    }
    nextToken = amiEc2.NextToken;
  } while (nextToken);

  const amiEc2 = options.maxItems === undefined ? images : images.slice(0, options.maxItems);
  logger.debug('Found the following AMIs', { images: amiEc2 });

  // sort oldest first
  amiEc2.sort((a, b) => {
    if (a.CreationDate && b.CreationDate) {
      return new Date(a.CreationDate).getTime() - new Date(b.CreationDate).getTime();
    } else {
      return 0;
    }
  });

  logger.info(`found #${amiEc2.length} images in ec2`);
  logger.info(`found #${amiIdsInSSM.length} images referenced in SSM`);
  logger.info(`found #${amiIdsInTemplates.length} images in latest versions of launch templates`);

  // Filter out AMIs that are referenced in either SSM parameters or Launch
  // Templates.
  const filteredAmiEc2 = amiEc2.filter(
    (image): image is Image & { ImageId: string } =>
      isAmiId(image.ImageId) && !amiIdsInSSM.includes(image.ImageId) && !amiIdsInTemplates.includes(image.ImageId),
  );

  logger.info(`found #${filteredAmiEc2.length} images in ec2 not in use.`);

  return filteredAmiEc2;
}

async function deleteAmi(
  amiDetails: Image & { ImageId: string },
  options: AmiCleanupOptionsInternal,
  evaluationTime: Date,
): Promise<void> {
  const creationDate = amiDetails.CreationDate ? new Date(amiDetails.CreationDate) : undefined;
  const minimumDaysOldDate = new Date(evaluationTime.getTime() - options.minimumDaysOld * 24 * 60 * 60 * 1000);
  if (!creationDate || !Number.isFinite(creationDate.getTime())) {
    logger.warn(`ami ${amiDetails.ImageId} has no valid creation date`);
    return;
  } else if (creationDate >= minimumDaysOldDate) {
    logger.debug(
      `ami ${amiDetails.Name || amiDetails.ImageId} created on ${amiDetails.CreationDate} is not deleted, ` +
        `not older then ${options.minimumDaysOld} days`,
    );
    return;
  }

  logger.info(
    `${options.dryRun ? 'would delete' : 'deleting'} ami ${amiDetails.Name || amiDetails.ImageId} ` +
      `created at ${amiDetails.CreationDate}`,
  );
  if (options.dryRun) {
    return;
  }

  const ec2Client = createMutationEc2Client();
  try {
    await ec2Client.send(
      new DeregisterImageCommand({
        ImageId: amiDetails.ImageId,
        DeleteAssociatedSnapshots: false,
      }),
      {
        abortSignal: AbortSignal.timeout(AWS_REQUEST_TIMEOUT_MS),
      },
    );
  } catch (error) {
    if (!isUnknownDeregistrationResult(error)) {
      throw error;
    }
    logger.warn(`DeregisterImage returned an unknown result for ${amiDetails.ImageId}; confirming by read-back`);
    await waitUntilImageIsNotAvailable(amiDetails.ImageId, ec2Client);
  }
  await deleteSnapshots(amiDetails, ec2Client);
}

function isUnknownDeregistrationResult(error: unknown): boolean {
  const details = error as {
    name?: string;
    code?: string;
    $metadata?: { httpStatusCode?: number };
  };
  const statusCode = details.$metadata?.httpStatusCode;
  return (
    statusCode === undefined ||
    statusCode >= 500 ||
    [
      'AbortError',
      'TimeoutError',
      'RequestTimeout',
      'RequestTimeoutException',
      'NetworkingError',
      'ECONNABORTED',
      'ECONNRESET',
    ].includes(details.name ?? details.code ?? '')
  );
}

async function waitUntilImageIsNotAvailable(imageId: string, ec2Client: EC2Client): Promise<void> {
  const deadline = performance.now() + DEREGISTRATION_CONFIRMATION_TIMEOUT_MS;

  while (performance.now() <= deadline) {
    try {
      const requestTimeRemaining = requestTimeoutWithinDeadline(deadline);
      const response = await ec2Client.send(
        new DescribeImagesCommand({
          Owners: ['self'],
          ImageIds: [imageId],
        }),
        {
          abortSignal: AbortSignal.timeout(requestTimeRemaining),
        },
      );
      const image = response.Images?.find((candidate) => candidate.ImageId === imageId);
      if (!image || image.State !== 'available') {
        return;
      }
    } catch (error) {
      const errorName = (error as { name?: string }).name;
      if (errorName === 'InvalidAMIID.NotFound') {
        return;
      }
    }

    if (performance.now() >= deadline) {
      break;
    }
    const remaining = deadline - performance.now();
    await new Promise((resolve) => setTimeout(resolve, Math.min(DEREGISTRATION_CONFIRMATION_POLL_MS, remaining)));
  }

  throw new Error(`Could not confirm deregistration for ${imageId} within 120 seconds`);
}

async function deleteSnapshots(amiDetails: Image, ec2Client: EC2Client): Promise<void> {
  const snapshotIds = (amiDetails.BlockDeviceMappings ?? [])
    .map((mapping) => mapping.Ebs?.SnapshotId)
    .filter((snapshotId): snapshotId is string => snapshotId !== undefined);

  const results = await Promise.allSettled(
    snapshotIds.map(async (snapshotId) => {
      try {
        logger.info(`deleting snapshot ${snapshotId} from ami ${amiDetails.ImageId}`);
        await ec2Client.send(new DeleteSnapshotCommand({ SnapshotId: snapshotId }), {
          abortSignal: AbortSignal.timeout(AWS_REQUEST_TIMEOUT_MS),
        });
      } catch (error) {
        const errorName = (error as { name?: string }).name;
        if (errorName === 'InvalidSnapshot.InUse' || errorName === 'InvalidSnapshot.NotFound') {
          logger.warn(`Retaining or skipping snapshot ${snapshotId} for ami ${amiDetails.ImageId}`, {
            reason: errorName,
          });
          return;
        }
        logger.error(`Cannot delete snapshot ${snapshotId} for ${amiDetails.Name || amiDetails.ImageId}`);
        logger.debug(`Cannot delete snapshot ${snapshotId} for ${amiDetails.Name || amiDetails.ImageId}`, { error });
        throw error;
      }
    }),
  );

  const errors = results
    .filter((result): result is PromiseRejectedResult => result.status === 'rejected')
    .map((result) => result.reason);
  if (errors.length > 0) {
    throw new AggregateError(errors, `Failed to delete ${errors.length} snapshot(s) for ${amiDetails.ImageId}`);
  }
}

/**
 * Resolves the values of multiple SSM parameters by their names.
 * Delegates batching to the shared `getParameters` utility.
 * @param names - Array of SSM parameter names to resolve
 * @returns Array of parameter values in the same order as input
 */
async function resolveSsmParameterValues(names: string[], ssmClient: SSMClient, sequential = false): Promise<string[]> {
  if (names.length === 0) {
    return [];
  }

  if (sequential) {
    const values: string[] = [];
    for (const name of names) {
      const parameterMap = await getParameters([name], {
        client: ssmClient,
        abortSignal: readAbortSignal(),
      });
      const value = parameterMap.get(name);
      if (!isAmiId(value)) {
        throw new Error(`Failed to resolve a valid image id from SSM parameter ${name}`);
      }
      values.push(value);
    }
    return values;
  }

  const parameterMap = await getParameters(names, {
    client: ssmClient,
    abortSignal: readAbortSignal(),
  });
  return names.map((name) => {
    const value = parameterMap.get(name);
    if (!isAmiId(value)) {
      throw new Error(`Failed to resolve a valid image id from SSM parameter ${name}`);
    }
    return value;
  });
}

/**
 * Retrieve AMI IDs referenced in Launch Templates.
 *
 * Discover AMI IDs that are actively used in Launch Templates, which indicates
 * they should not be cleaned up.
 *
 * @param options - Cleanup configuration including optional launch template name filters
 * @returns Array of AMI IDs found in launch templates
 */
async function getAmiInLatestTemplates(options: AmiCleanupOptions): Promise<string[]> {
  const ec2Client = createReadEc2Client();

  // Discover launch templates, optionally filtered by specific names. If no
  // names provided, this will return all launch templates in the account
  logger.debug('Describing launch templates', {
    launchTemplateNames: options.launchTemplateNames,
  });
  const launchTemplates = [];
  let nextToken: string | undefined;
  do {
    const response = await ec2Client.send(
      new DescribeLaunchTemplatesCommand({
        LaunchTemplateNames: options.launchTemplateNames,
        NextToken: nextToken,
      }),
      { abortSignal: readAbortSignal() },
    );
    launchTemplates.push(...(response.LaunchTemplates ?? []));
    nextToken = response.NextToken;
  } while (nextToken);
  logger.debug('Found launch templates', { launchTemplates });

  if (options.launchTemplateNames && options.launchTemplateNames.length > 0) {
    const foundNames = new Set(launchTemplates.map((template) => template.LaunchTemplateName));
    const missingNames = options.launchTemplateNames.filter((name) => !foundNames.has(name));
    if (missingNames.length > 0) {
      throw new Error(`Requested launch template(s) not found: ${missingNames.join(', ')}`);
    }
  }

  // For each template, fetch the default version and resolve any SSM aliases.
  const amiIds = await Promise.all(
    launchTemplates.map(async (template) => {
      if (!template.LaunchTemplateId) {
        throw new Error(`Launch template ${template.LaunchTemplateName ?? '<unnamed>'} has no id`);
      }
      const versionsResp = await ec2Client.send(
        new DescribeLaunchTemplateVersionsCommand({
          LaunchTemplateId: template.LaunchTemplateId,
          Versions: ['$Default'], // Only check the default version
          // This means that references like `resolve:ssm:<parameter arn>` are
          // dereferenced.
          ResolveAlias: true,
        }),
        { abortSignal: readAbortSignal() },
      );

      logger.debug('Found launch template versions', { versionsResp });
      const versions = versionsResp.LaunchTemplateVersions ?? [];
      const imageId = versions[0]?.LaunchTemplateData?.ImageId;
      if (versions.length !== 1 || !isAmiId(imageId)) {
        throw new Error(`Failed to resolve a valid image id from launch template ${template.LaunchTemplateName}`);
      }
      return imageId;
    }),
  );

  logger.debug('Found AMIs in launch templates', { amiIds });
  return amiIds;
}

/**
 * Retrieve AMI IDs referenced in SSM Parameters.
 *
 * Resolve AMI IDs stored in SSM parameters, supporting both literal parameter
 * names and wildcard patterns.
 *
 * @param options - Cleanup configuration including SSM parameter names/patterns to check
 * @returns Array of AMI IDs found in SSM parameters
 */
async function getAmisReferedInSSM(options: AmiCleanupOptions): Promise<string[]> {
  if (!options.ssmParameterNames || options.ssmParameterNames.length === 0) {
    return [];
  }

  const ssmClient = createReadSsmClient();

  // Categorise parameter names into two groups for different handling strategies:
  // 1. Explicit names: Direct parameter lookups (e.g.,
  //    "/github-runner/config/ami_id"). These can be looked up directly.
  // 2. Wildcard patterns: Require parameter discovery first (e.g., "*ami-id",
  //    "*ami_id"). For these, we need to enumerate.
  const explicitNames = options.ssmParameterNames.filter((n) => !n.startsWith('*'));
  const wildcardPatterns = options.ssmParameterNames.filter((n) => n.startsWith('*'));

  // Batch fetch explicit parameter values in chunks of 10 (AWS API limit)
  // Release callers order each architecture as active, previous, recovery.
  // Reading those names sequentially preserves the recovery-first writer
  // invariant without assuming GetParameters is an atomic multi-key snapshot.
  const explicitValuesPromise = resolveSsmParameterValues(explicitNames, ssmClient, true);

  // Handle wildcard patterns by first discovering matching parameters, then
  // fetching their values
  let wildcardValuesPromise: Promise<string[]> = Promise.resolve([]);
  if (wildcardPatterns.length > 0) {
    // Convert wildcard patterns to SSM ParameterFilters using Contains logic
    // Example: "*ami-id" becomes a filter for parameters containing "ami-id"
    const filters = wildcardPatterns.map((p) => ({
      Key: 'Name',
      Option: 'Contains',
      Values: [p.replace(/^\*/g, '')],
    }));

    wildcardValuesPromise = (async () => {
      const discoveredNames: string[] = [];
      let nextToken: string | undefined;
      do {
        logger.debug('Describing SSM parameter', { filters });
        const ssmParameters = await ssmClient.send(
          new DescribeParametersCommand({ ParameterFilters: filters, NextToken: nextToken }),
          { abortSignal: readAbortSignal() },
        );
        discoveredNames.push(
          ...(ssmParameters.Parameters ?? [])
            .map((param) => param.Name)
            .filter((name): name is string => name !== undefined),
        );
        nextToken = ssmParameters.NextToken;
      } while (nextToken);

      return resolveSsmParameterValues(discoveredNames, ssmClient);
    })();
  }

  // Combine results from both explicit and wildcard parameter resolution
  const [explicitValues, wildcardValues] = await Promise.all([explicitValuesPromise, wildcardValuesPromise]);
  const values = [...explicitValues, ...wildcardValues];
  logger.debug('Resolved SSM parameter values', { values });
  return values;
}

export { amiCleanup, createMutationEc2Client, getAmisNotInUse, requestTimeoutWithinDeadline };
