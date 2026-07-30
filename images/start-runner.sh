#!/bin/bash -e
exec > >(tee /var/log/runner-startup.log | logger -t user-data -s 2>/dev/console) 2>&1

validation_mode_status=0
/opt/actions-runner/bin/is-ami-validation.sh || validation_mode_status=$?
case "$validation_mode_status" in
  0)
    echo "AMI validation mode detected; skipping GitHub runner registration"
    exit 0
    ;;
  1)
    ;;
  *)
    echo "Unable to determine AMI validation mode; refusing runner registration" >&2
    exit "$validation_mode_status"
    ;;
esac

cd /opt/actions-runner

## This wrapper file reuses scripts in the /modules/runners/templates directory
## of this repo. These are the same that are used by the user_data functionality 
## to bootstrap the instance if it is started from an existing AMI.
# shellcheck disable=SC2154 # Rendered by Packer before this script runs.
${start_runner}
