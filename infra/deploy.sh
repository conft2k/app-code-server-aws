#!/usr/bin/env bash
# code2 operations. Infrastructure goes through CloudFormation change sets (plan, look, then apply).
set -euo pipefail

usage() {
  cat <<'EOF'
infra/deploy.sh <command>

  stack plan          change set for the code2 stack (infra/code2.yaml); changes nothing
  stack apply         execute the change set made by the last plan
  status              URL, instance state, services, /home usage
  logs [-f] [since]   setup log from CloudWatch Logs (default since 1h)
  reconfigure         upload infra/setup.sh and run it on the instance (no restart; apply does this too)
  ssh [args]          SSH as ec2-user through the stack's EICE (one-off key via EC2 Instance Connect)
  ssh-config          ~/.ssh/config block for ssh / VS Code Remote-SSH (keys must be pushed per use)
  shell               Session Manager shell on the instance
  stop | start        stop or start the instance (the NAT gateway keeps billing while stopped)
  destroy             delete the stack, then list what it leaves behind (user pool, snapshots)

Settings (environment). Unset ones keep their current value on update; create-time ones are fixed after create.
  CODE2_ADMIN_EMAIL            required on create: the sign-in email, where Cognito sends the temporary password
                               (a new address recreates the user)
  CODE2_STACK                  stack name, lowercase (default code2)
  CODE2_ACCOUNT                refuse to run with credentials for any other account
  AWS_REGION                   default: AWS_DEFAULT_REGION, the profile's region, then ap-northeast-2
  CODE2_INSTANCE_TYPE          default t4g.medium; any Nitro type, Graviton or x86 (another architecture replaces the instance)
  CODE2_DATA_SIZE              /home GiB (default 50, grow only)
  CODE2_ROOT_SIZE              root GiB (default 30, a change replaces the instance)
  CODE2_CODE_SERVER_VERSION    code-server version (installed in place, no restart)
  CODE2_OAUTH2_PROXY_VERSION   oauth2-proxy version (installed in place, no restart)
  CODE2_SESSION_HOURS          sign-in lifetime (default 12)
  CODE2_MFA                    on|off TOTP at sign-in (default on)
  CODE2_PASSWORD_MIN_LENGTH    minimum password length, 8-99 (default 12)
  CODE2_AUTO_UPDATES           true|false daily security updates (default true)
  CODE2_AI_TOOLS               on|off install Claude Code and Codex for ec2-user (default on; off keeps installed ones)
  CODE2_BEDROCK                on|off let the instance role call Bedrock, and set both tools up for it on a new /home
                               (default on for a new stack, off for one that predates it)
  CODE2_BEDROCK_REGION         region the tools call Bedrock in (default: the stack's)
  CODE2_CODEX_MODEL            Codex model on Bedrock (default global.openai.gpt-6.1-sol)
  CODE2_IDLE_STOP_HOURS        stop after this many idle hours (default 0 = never)
  CODE2_BACKUP_COUNT           daily /home snapshots kept (default 7, 0 = off)
  CODE2_ALARM_EMAIL            CloudWatch alarm mails (default none)
  CODE2_YES=1                  destroy: skip the confirmation; stack plan: ask nothing
  CODE2_PRICE_CLASS            PriceClass_100|200|All (default PriceClass_200)
  CODE2_UPDATE_AMI=1           move to the latest AL2023 AMI (replaces the instance; /home stays)
  CODE2_KEEP_ON_FAILURE=1      apply without rollback, to inspect a failed create
  create-time:
  CODE2_AZ                     AZ (default: the first one offering the instance type)
  CODE2_RESTORE_SNAPSHOT       snap-... to create /home from (a snapshot of an earlier code2 /home)

In a terminal, stack plan asks for the region and stack name, and for a new stack the main settings, unless they
are exported. Without a terminal, or with CODE2_YES=1, it asks nothing and uses the environment.
EOF
  exit 2
}

die() { echo "$*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

case "${1:-}" in ""|-h|--help|help) usage ;; esac
command -v jq >/dev/null || die "jq is required"
CLI_HELP="install AWS CLI v2 (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), then sign in (aws configure, aws login or aws sso login) and check with: aws sts get-caller-identity"
command -v aws >/dev/null || die "AWS CLI v2 is required: $CLI_HELP"
aws --version 2>&1 | grep -q '^aws-cli/2' || die "AWS CLI v2 is required (found: $(aws --version 2>&1)): $CLI_HELP"

TMP_STS=$(mktemp); trap 'rm -f "$TMP_STS"' EXIT
# plan asks for what is not set here (ask_basics), so remember what the environment gave.
region_given=0 stack_given=0
if [ -n "${AWS_REGION+x}${AWS_DEFAULT_REGION+x}" ]; then region_given=1; fi
if [ -n "${CODE2_STACK+x}" ]; then stack_given=1; fi
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}
export AWS_REGION=${region:-ap-northeast-2}
STACK=${CODE2_STACK:-code2}
TEMPLATE=$(cd "$(dirname "$0")" && pwd)/code2.yaml
SETUP=$(dirname "$TEMPLATE")/setup.sh

# A region the user has not given may be a typo in the profile (plan asks for it later), so STS is tried in us-east-1
# too: any region's endpoint returns the same account.
caller=$(aws sts get-caller-identity --query Account --output text 2>"$TMP_STS" || echo none)
if [ "$caller" = none ] && [ "$region_given" = 0 ]; then
  caller=$(aws sts get-caller-identity --region us-east-1 --query Account --output text 2>"$TMP_STS" || echo none)
fi
if [ "$caller" = none ]; then
  sed 's/^/  /' "$TMP_STS" >&2
  die "no usable AWS credentials: sign in first (aws configure, aws login, aws sso login, or AWS_PROFILE=...) and check with: aws sts get-caller-identity"
fi
if [ -n "${CODE2_ACCOUNT:-}" ] && [ "$caller" != "$CODE2_ACCOUNT" ]; then
  die "refusing to run: credentials are for account $caller, CODE2_ACCOUNT is $CODE2_ACCOUNT"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$TMP_STS"' EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
is_set() { declare -p "$1" >/dev/null 2>&1; }

# The instance runs setup.sh from here (<bucket>/<stack>/setup.sh); one bucket per account and region.
BUCKET="code2-setup-$caller-$AWS_REGION"
ensure_bucket() {
  # Every call names the owner: the name is predictable, and another account's bucket must never be used.
  aws s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$caller" >/dev/null 2>&1 && return
  echo "creating s3://$BUCKET for setup.sh"
  local loc=(--create-bucket-configuration "LocationConstraint=$AWS_REGION")
  [ "$AWS_REGION" != us-east-1 ] || loc=()
  aws s3api create-bucket --bucket "$BUCKET" ${loc[@]+"${loc[@]}"} >/dev/null \
    || die "cannot create s3://$BUCKET (if another account owns that name, this account cannot use it)"
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(jq -nc --arg b "$BUCKET" '{Version: "2012-10-17", Statement: [{
    Sid: "TlsOnly", Effect: "Deny", Principal: "*", Action: "s3:*", Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"],
    Condition: {Bool: {"aws:SecureTransport": "false"}}}]}')"
}
# upload_setup keeps the replaced copy in $TMP/prev-setup.sh, so a failed apply can put it back (restore_setup).
upload_setup() {
  ensure_bucket
  aws s3api get-object --bucket "$BUCKET" --key "$STACK/setup.sh" --expected-bucket-owner "$caller" \
    "$TMP/prev-setup.sh" >/dev/null 2>&1 || rm -f "$TMP/prev-setup.sh"
  put_setup "$SETUP"
}
# s3api, not s3 cp: only s3api takes --expected-bucket-owner.
put_setup() {
  aws s3api put-object --bucket "$BUCKET" --key "$STACK/setup.sh" --body "$1" --expected-bucket-owner "$caller" >/dev/null
}
restore_setup() {
  [ -f "$TMP/prev-setup.sh" ] || return 0
  echo "putting the previous setup.sh back (the stack's settings rolled back)"
  put_setup "$TMP/prev-setup.sh" || true
}

# ---------- stack state ----------
stack_status() { aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE; }
has_resource() { aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id "$1" >/dev/null 2>&1; }
physical_id() { aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id "$1" \
  --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null || true; }

# Stops on states a change set cannot start from, with what to do instead.
check_state() {
  local s; s=$(stack_status)
  case "$s" in
    NONE|REVIEW_IN_PROGRESS|*_COMPLETE) ;;
    *_IN_PROGRESS) die "$STACK is busy ($s); wait for it to finish" ;;
    UPDATE_ROLLBACK_FAILED) die "$STACK is $s: fix the cause shown in its events, then run
  aws cloudformation continue-update-rollback --stack-name $STACK" ;;
    CREATE_FAILED) die "$STACK failed to create (kept for inspection); run infra/deploy.sh destroy, then plan again" ;;
    *) die "$STACK is $s: see its events (aws cloudformation describe-stack-events --stack-name $STACK)" ;;
  esac
  if [ "$s" = ROLLBACK_COMPLETE ]; then
    die "$STACK failed to create and rolled back, so it cannot be updated. See why with
  aws cloudformation describe-stack-events --stack-name $STACK
then run infra/deploy.sh destroy and plan again"
  fi
}

# ---------- parameters ----------
PARAMS='[]'
param() { PARAMS=$(jq -c --arg k "$1" --arg v "$2" '. + [{ParameterKey: $k, ParameterValue: $v}]' <<<"$PARAMS"); }
keep() { PARAMS=$(jq -c --arg k "$1" '. + [{ParameterKey: $k, UsePreviousValue: true}]' <<<"$PARAMS"); }

# ParameterKey:ENV pairs that may change after create.
TUNABLES="InstanceType:CODE2_INSTANCE_TYPE DataVolumeSize:CODE2_DATA_SIZE RootVolumeSize:CODE2_ROOT_SIZE
  CodeServerVersion:CODE2_CODE_SERVER_VERSION OAuth2ProxyVersion:CODE2_OAUTH2_PROXY_VERSION
  SessionHours:CODE2_SESSION_HOURS Mfa:CODE2_MFA PasswordMinLength:CODE2_PASSWORD_MIN_LENGTH AutoUpdates:CODE2_AUTO_UPDATES AiTools:CODE2_AI_TOOLS IdleStopHours:CODE2_IDLE_STOP_HOURS
  Bedrock:CODE2_BEDROCK BedrockRegion:CODE2_BEDROCK_REGION CodexModel:CODE2_CODEX_MODEL
  BackupRetainCount:CODE2_BACKUP_COUNT AlarmEmail:CODE2_ALARM_EMAIL PriceClass:CODE2_PRICE_CLASS
  AdminEmail:CODE2_ADMIN_EMAIL"
# Fixed after create (network, the volume's source, the boot signal).
CREATE_ONLY="AvailabilityZone VpcCidr PublicSubnetCidr PrivateSubnetCidr DataSnapshotId WaitForBoot"

arch_of() { aws ec2 describe-instance-types --instance-types "$1" --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' \
  --output text 2>/dev/null | tr '\t' '\n' | grep -E '^(arm64|x86_64)$' | head -1 || true; }
# The instance finds /home by its NVMe serial, which only Nitro (and bare metal) types expose; Xen types (t2, m4, c4)
# would wait for the volume and fail.
nitro_problem() {
  local hv metal
  read -r hv metal < <(aws ec2 describe-instance-types --instance-types "$1" \
    --query 'InstanceTypes[0].[Hypervisor,BareMetal]' --output text 2>/dev/null || echo "none False")
  [ "$hv" = nitro ] || [ "$metal" = True ] || {
    echo "$1 is not a Nitro instance type (hypervisor $hv); code2 needs one, e.g. t4g, t3, m7g, m7i"; return 1; }
}
check_nitro() { local r; r=$(nitro_problem "$1") || die "$r"; }
latest_ami() { aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$1" \
  --query Parameter.Value --output text; }

# The instance's :80 accepts CloudFront's origin-facing addresses only (VPC origin traffic comes from them).
prefix_list() {
  local id
  id=$(aws ec2 describe-managed-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)
  [[ "$id" == pl-* ]] || die "no CloudFront origin-facing prefix list in $AWS_REGION"
  echo "$id"
}

# ---------- interactive plan (a terminal only; exported values are never asked) ----------
# name@domain.tld: dot-separated parts, no leading/trailing/double dots, a letter TLD (rejects you@example, <you@example.com>).
EMAIL_ATOM="[A-Za-z0-9!#\$%&'*+/=?^_\`{|}~-]+"   # RFC 5322 atext
EMAIL_RE="^$EMAIL_ATOM(\\.$EMAIL_ATOM)*@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\\.[A-Za-z]{2,}\$"
interactive() { [ -t 0 ] && [ "${CODE2_YES:-}" != 1 ]; }

# stack_name_problem <name>: prints why the name is unusable (shared by the prompt and preflight_create).
stack_name_problem() {
  [[ "$1" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] \
    || { echo "must start with a letter and use only lowercase letters, digits and hyphens (not at the end)"; return 1; }
  [ ${#1} -le 50 ] || { echo "is longer than 50 characters (it prefixes the Cognito domain)"; return 1; }
  if [[ "$1" =~ aws|amazon|cognito ]]; then echo "cannot contain aws, amazon or cognito (Cognito domain rule)"; return 1; fi
  return 0
}
# Checks for ask: print the reason and return 1 when the answer is not usable.
chk_region() {
  local r
  # Asked in the region itself: AWS_REGION may still be the profile's unusable value.
  r=$(aws ec2 describe-regions --region "$1" --region-names "$1" --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
    --query 'Regions[0].RegionName' --output text 2>/dev/null || true)
  [ "$r" = "$1" ] || { echo "$1 is not a region enabled for this account; enter a region code like ap-northeast-2"; return 1; }
}
chk_stack() { local r; r=$(stack_name_problem "$1") || { echo "stack name $r"; return 1; }; }
chk_email() { [[ "$1" =~ $EMAIL_RE ]] || { echo "enter an email address like you@example.com"; return 1; }; }
chk_email_or_empty() {
  case "$1" in n|no|none|-) echo "leave it empty (press Enter) for no alarm email"; return 1 ;; esac
  [ -z "$1" ] || chk_email "$1"
}
chk_onoff() { [ "$1" = on ] || [ "$1" = off ] || { echo "answer on or off"; return 1; }; }
chk_type() {
  local arch r
  arch=$(arch_of "$1"); [ -n "$arch" ] || { echo "unknown instance type $1 in $AWS_REGION"; return 1; }
  r=$(nitro_problem "$1") || { echo "$r"; return 1; }
}
chk_data() { { [[ "$1" =~ ^[0-9]{1,6}$ ]] && [ "$1" -ge 20 ]; } || { echo "enter a whole number of GiB, 20 or more"; return 1; }; }
chk_idle() { { [[ "$1" =~ ^[0-9]{1,3}$ ]] && [ "$1" -le 72 ]; } || { echo "enter whole hours from 0 to 72"; return 1; }; }

# ask <VAR> <prompt> <default> <check>: asks until the check passes (Enter takes the default), then exports VAR.
ask() {
  local var=$1 prompt=$2 def=$3 check=$4 ans err
  while :; do
    read -rp "$prompt " ans || die "stopped; nothing was changed"
    ans=${ans:-$def}
    case "$var" in AWS_REGION|CODE2_MFA|CODE2_AI_TOOLS|CODE2_BEDROCK|CODE2_INSTANCE_TYPE) ans=$(printf %s "$ans" | tr '[:upper:]' '[:lower:]') ;; esac
    if err=$("$check" "$ans"); then break; fi
    echo "  $err" >&2
  done
  export "$var=$ans"
}

# Region and stack name; returns 1 when the stack exists (an update asks nothing more).
ask_basics() {
  local def
  echo "Press Enter to take the [default]; Ctrl-D stops without changing anything." >&2
  if [ "$region_given" = 0 ]; then
    def=$(aws configure get region 2>/dev/null || true); def=${def:-ap-northeast-2}
    ask AWS_REGION "Region [$def]:" "$def" chk_region
    BUCKET="code2-setup-$caller-$AWS_REGION"
  fi
  if [ "$stack_given" = 0 ]; then
    ask CODE2_STACK "Stack name [code2]:" code2 chk_stack
    STACK=$CODE2_STACK
  fi
  check_state
  case "$(stack_status)" in
    NONE|REVIEW_IN_PROGRESS|DELETE_COMPLETE) echo "$STACK does not exist in $AWS_REGION; it will be created." >&2 ;;
    *) echo "$STACK exists in $AWS_REGION; plan keeps its current settings for anything not exported." >&2; return 1 ;;
  esac
}

# The create-time settings, then the command to repeat them and the go-ahead. Runs before any AWS write.
ask_create() {
  local line v ans
  is_set CODE2_ADMIN_EMAIL || ask CODE2_ADMIN_EMAIL "Sign-in email (the temporary password goes here):" "" chk_email
  is_set CODE2_MFA || ask CODE2_MFA "Multi-factor authentication: ask for an authenticator app code at sign-in (on/off) [on]:" on chk_onoff
  is_set CODE2_INSTANCE_TYPE || ask CODE2_INSTANCE_TYPE "Instance type [t4g.medium]:" t4g.medium chk_type
  is_set CODE2_DATA_SIZE || ask CODE2_DATA_SIZE "/home size in GiB, can only grow [50]:" 50 chk_data
  is_set CODE2_IDLE_STOP_HOURS || ask CODE2_IDLE_STOP_HOURS "Stop after idle hours, 0 = never [0]:" 0 chk_idle
  is_set CODE2_AI_TOOLS || ask CODE2_AI_TOOLS "Install Claude Code and Codex (on/off) [on]:" on chk_onoff
  if [ "${CODE2_AI_TOOLS:-on}" = on ]; then
    is_set CODE2_BEDROCK || ask CODE2_BEDROCK "Use Amazon Bedrock in this account for Claude Code and Codex (on/off) [on]:" on chk_onoff
  fi
  is_set CODE2_ALARM_EMAIL || ask CODE2_ALARM_EMAIL "Alarm email, empty = none []:" "" chk_email_or_empty
  # Every create setting in effect, asked or exported, so the line repeats this plan without questions.
  line="AWS_REGION=$(printf %q "$AWS_REGION") CODE2_STACK=$(printf %q "$STACK")"
  for v in $(for pair in $TUNABLES; do echo "${pair#*:}"; done) CODE2_AZ CODE2_RESTORE_SNAPSHOT; do
    if is_set "$v"; then line="$line $v=$(printf %q "${!v}")"; fi
  done
  local idle=never alarm=none
  [ "${CODE2_IDLE_STOP_HOURS:-0}" = 0 ] || idle="after ${CODE2_IDLE_STOP_HOURS} idle hours"
  [ -z "${CODE2_ALARM_EMAIL:-}" ] || alarm=$CODE2_ALARM_EMAIL
  {
    echo
    echo "New stack $STACK in $AWS_REGION, account $caller:"
    echo "  sign-in email       $CODE2_ADMIN_EMAIL (the temporary password goes here; check it)"
    echo "  MFA                 ${CODE2_MFA:-on}"
    echo "  instance type       ${CODE2_INSTANCE_TYPE:-t4g.medium}"
    echo "  /home               ${CODE2_DATA_SIZE:-50} GiB"
    echo "  stop                $idle"
    echo "  Claude Code, Codex  ${CODE2_AI_TOOLS:-on}"
    [ "${CODE2_AI_TOOLS:-on}" != on ] || echo "  Amazon Bedrock      ${CODE2_BEDROCK:-on}"
    echo "  alarm email         $alarm"
    echo "Nothing is built yet: plan only makes a change set. infra/deploy.sh stack apply builds it (about 15-20 minutes)."
    printf 'To run the same again without questions:\n  export %s\n' "$line"
  } >&2
  while :; do
    read -rp "Continue with these settings? [Y/n] " ans || ans=n
    case "$ans" in
      ""|[Yy]|[Yy][Ee][Ss]) break ;;
      [Nn]|[Nn][Oo]) die "stopped; nothing was changed" ;;
      *) echo "  answer y or n" >&2 ;;
    esac
  done
}

preflight_create() {
  local type=$1 az=$2 n r
  r=$(stack_name_problem "$STACK") || die "CODE2_STACK $r"
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=location,Values=$az" "Name=instance-type,Values=$type" --query 'InstanceTypeOfferings[0]' \
    --output text | grep -q "$type" || die "$type is not offered in $az (set CODE2_AZ or CODE2_INSTANCE_TYPE)"
  n=$(aws ec2 describe-instance-connect-endpoints --query 'length(InstanceConnectEndpoints)' --output text 2>/dev/null || echo 0)
  [ "$n" -lt 5 ] || warn "$n EC2 Instance Connect Endpoints in $AWS_REGION already (default quota 5)"
  n=$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text)
  [ "$n" -lt 5 ] || warn "$n VPCs in $AWS_REGION already (default quota 5)"
  n=$(aws ec2 describe-addresses --query 'length(Addresses)' --output text)
  [ "$n" -lt 5 ] || warn "$n Elastic IPs in $AWS_REGION already (default quota 5)"
}

params_create() {
  local type=${CODE2_INSTANCE_TYPE:-t4g.medium} arch ami az="${CODE2_AZ:-}" pair k v pl
  [ -n "${CODE2_ADMIN_EMAIL:-}" ] || die "set CODE2_ADMIN_EMAIL (the temporary password goes there)"
  arch=$(arch_of "$type"); [ -n "$arch" ] || die "unknown instance type $type in $AWS_REGION"
  check_nitro "$type"
  ami=$(latest_ami "$arch"); param ImageId "$ami"
  pl=$(prefix_list); param CloudFrontPrefixListId "$pl"
  param SetupBucket "$BUCKET"

  if [ -z "$az" ]; then
    az=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=$type" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort | head -1)
    [ -n "$az" ] || die "$type is not offered in any AZ of $AWS_REGION"
  fi
  preflight_create "$type" "$az"
  param AvailabilityZone "$az"

  [ -z "${CODE2_RESTORE_SNAPSHOT:-}" ] || param DataSnapshotId "$CODE2_RESTORE_SNAPSHOT"

  for pair in $TUNABLES; do
    k=${pair%%:*} v=${pair#*:}
    if is_set "$v"; then param "$k" "${!v}"; fi
  done
  # No AI tools: nothing would use Bedrock, so the role does not get it unless asked.
  [ "${CODE2_AI_TOOLS:-on}" = on ] || is_set CODE2_BEDROCK || param Bedrock off
  echo "create $STACK in $AWS_REGION ($caller): $type $arch in $az"
}

params_update() {
  local existing pair k v cur_type new_type cur_arch new_arch ami pl
  existing=" $(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Parameters[].ParameterKey' --output text | tr '\t' ' ') "
  has() { [[ "$existing" == *" $1 "* ]]; }

  for pair in $TUNABLES; do
    k=${pair%%:*} v=${pair#*:}
    if is_set "$v"; then param "$k" "${!v}"; elif has "$k"; then keep "$k"; fi
  done
  # A stack that predates Bedrock gets it only when asked: its /home exists, so nothing would set the tools up.
  has Bedrock || is_set CODE2_BEDROCK || param Bedrock off
  pl=$(prefix_list); param CloudFrontPrefixListId "$pl"   # always current; older stacks lack it
  param SetupBucket "$BUCKET"
  for k in $CREATE_ONLY; do
    if has "$k"; then keep "$k"
    elif [ "$k" = WaitForBoot ]; then param WaitForBoot false   # the running instance predates the boot signal
    fi
  done
  if has OriginSlot; then keep OriginSlot; fi
  for v in CODE2_AZ CODE2_RESTORE_SNAPSHOT; do
    [ -z "${!v:-}" ] || warn "$v only applies when the stack is created; ignored"
  done

  # A new AMI replaces the instance (the replacement attaches /home once CloudFormation terminates the old one).
  cur_type=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='InstanceType'].ParameterValue" --output text)
  new_type=${CODE2_INSTANCE_TYPE:-$cur_type}
  cur_arch=$(arch_of "$cur_type"); new_arch=$(arch_of "$new_type")
  [ -n "$new_arch" ] || die "unknown instance type $new_type in $AWS_REGION"
  check_nitro "$new_type"
  if [ "${CODE2_UPDATE_AMI:-}" = 1 ] || [ "$cur_arch" != "$new_arch" ]; then
    [ "$cur_arch" = "$new_arch" ] || echo "$cur_type ($cur_arch) -> $new_type ($new_arch): the instance is replaced with a $new_arch AMI"
    ami=$(latest_ami "$new_arch"); param ImageId "$ami"
  else
    keep ImageId
  fi
  echo "update $STACK in $AWS_REGION ($caller)"
}

# ---------- migration from the template with AWS::EC2::VolumeAttachment ----------
# Removing that resource would detach the mounted /home. Step 1 re-deploys the running template with the attachment
# retained; step 2 (the normal plan) then drops it from the stack while the volume stays attached.
MIGRATION_MARK=MigrationKeepsDataVolumeAttachment
legacy_template() {
  aws cloudformation get-template --stack-name "$STACK" --template-stage Original --query TemplateBody --output text
}

# Users sign in with their email (UsernameAttributes), which Cognito fixes when a user pool is created. A stack from
# an earlier template (a separate sign-in name with an email alias) cannot be updated to it in place.
check_email_signin() {
  local pool attrs
  pool=$(aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id UserPool \
    --query StackResourceDetail.PhysicalResourceId --output text) || die "cannot read the UserPool resource of $STACK"
  [ -n "$pool" ] && [ "$pool" != None ] || die "$STACK has no UserPool resource; cannot check its sign-in mode"
  attrs=$(aws cognito-idp describe-user-pool --user-pool-id "$pool" --query 'UserPool.UsernameAttributes' --output text) \
    || die "cannot read user pool $pool"
  [[ "$attrs" == *email* ]] || die "$STACK was created by an older template whose user pool signs in with a user name, not \
an email; Cognito cannot change that in place. Create a new stack with another CODE2_STACK (CODE2_RESTORE_SNAPSHOT=<a /home \
snapshot> brings the workspace along), then destroy this one."
}

# ---------- change sets ----------
# make_change_set <type> <template> <kind>: creates change set $cs from $PARAMS; fails when it has no changes.
make_change_set() {
  local status reason
  echo "$PARAMS" > "$TMP/params.json"
  [ "$(wc -c < "$2")" -le 51200 ] || die "$2 is over 51,200 bytes, the limit for a template body"
  cs="$STACK-$(date -u +%Y%m%d-%H%M%S)-$RANDOM"
  aws cloudformation create-change-set --stack-name "$STACK" --change-set-name "$cs" --change-set-type "$1" \
    --template-body "file://$2" --capabilities CAPABILITY_IAM --tags Key=project,Value=code2 \
    --parameters "file://$TMP/params.json" --description "code2 $3 sha256=$(sha256 "$2") setup=$(sha256 "$SETUP")" \
    --query Id --output text >/dev/null
  aws cloudformation wait change-set-create-complete --stack-name "$STACK" --change-set-name "$cs" 2>/dev/null || true
  read -r status reason < <(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$cs" \
    --query '[Status,StatusReason]' --output text)
  if [ "$status" = FAILED ]; then
    aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$cs"
    [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]] && return 1
    die "change set failed: $reason"
  fi
}

# recreates_instance <change set>: the change set may replace the instance (any property needing recreation).
# UserData and InstanceType report "Conditionally" but only stop and start an EBS-backed instance, so they do
# not count. A type of another architecture also changes ImageId, which reports "Always".
recreates_instance() {
  aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$1" --output json | jq -e \
    '[.Changes[].ResourceChange | select(.LogicalResourceId == "Instance") | .Details[].Target
      | select(.RequiresRecreation == "Always"
          or (.RequiresRecreation == "Conditionally" and (.Name | IN("UserData", "InstanceType") | not)))]
     | length > 0' >/dev/null
}

plan() {
  local type template kind cs ask_more=0
  if interactive; then ask_basics || ask_more=1; fi   # 1: the stack exists, nothing more to ask
  if [ -n "${CODE2_BEDROCK_REGION:-}" ]; then
    local r; r=$(chk_region "$CODE2_BEDROCK_REGION") || die "CODE2_BEDROCK_REGION: $r"
  fi
  check_state
  case "$(stack_status)" in NONE|REVIEW_IN_PROGRESS|DELETE_COMPLETE) type=CREATE ;; *) type=UPDATE ;; esac
  template=$TEMPLATE kind=main
  [ "$type" = CREATE ] || check_email_signin

  if [ "$type" = UPDATE ] && has_resource DataVolumeAttachment; then
    legacy_template > "$TMP/deployed.yaml"
    if ! grep -q "$MIGRATION_MARK" "$TMP/deployed.yaml"; then
      kind=migrate template=$TMP/migrate.yaml
      awk '{ print } /Type: AWS::EC2::VolumeAttachment/ { print "    DeletionPolicy: Retain"; print "    UpdateReplacePolicy: Retain" }' "$TMP/deployed.yaml" > "$template"
      printf '  %s:\n    Value: "true"\n' "$MIGRATION_MARK" >> "$template"
      PARAMS=$(aws cloudformation describe-stacks --stack-name "$STACK" --output json \
        | jq -c '[.Stacks[0].Parameters[] | {ParameterKey, UsePreviousValue: true}]')
      echo "migration step 1/2: keep the /home volume attachment when it leaves the template (no resource changes)"
    else
      echo "migration step 2/2: the stack moves to the current template; the /home volume stays attached"
      params_update
    fi
  elif [ "$type" = UPDATE ]; then
    params_update
  else
    if interactive && [ "$ask_more" = 0 ]; then ask_create; fi
    params_create
  fi

  make_change_set "$type" "$template" "$kind" || { echo "no stack changes (infra/deploy.sh reconfigure applies infra/setup.sh)"; return 0; }

  # A VPC origin in use cannot move to another instance: when the instance is recreated, plan again with the other
  # origin slot, so CloudFormation makes a new origin, moves the distribution and deletes the old one.
  if [ "$kind" = main ] && [ "$type" = UPDATE ] && recreates_instance "$cs"; then
    local slot
    slot=$(aws cloudformation describe-stacks --stack-name "$STACK" \
      --query "Stacks[0].Parameters[?ParameterKey=='OriginSlot'].ParameterValue" --output text)
    [ "$slot" = b ] && slot=a || slot=b
    echo "the instance is replaced: the distribution moves to VPC origin slot $slot"
    aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$cs"
    PARAMS=$(jq -c --arg s "$slot" 'map(select(.ParameterKey != "OriginSlot")) + [{ParameterKey: "OriginSlot", ParameterValue: $s}]' <<<"$PARAMS")
    make_change_set "$type" "$template" "$kind" || die "the slot change set unexpectedly had no changes"
  fi

  echo "change set $cs ($type $STACK):"
  aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$cs" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output table
  echo "apply it with: infra/deploy.sh stack apply"
}

apply() {
  local cs desc type rollback=()
  read -r cs desc < <(aws cloudformation list-change-sets --stack-name "$STACK" --output json | jq -r \
    '[.Summaries[] | select(.Status == "CREATE_COMPLETE" and .ExecutionStatus == "AVAILABLE")] | sort_by(.CreationTime) | last
     | select(.) | [.ChangeSetName, (.Description // "")] | @tsv') || true
  [ -n "${cs:-}" ] || die "no pending change set for $STACK; run plan first"
  # A plan of an older template or setup.sh must not be applied over a newer checkout.
  if [[ "$desc" == "code2 main sha256="* ]] && [ "${desc#*sha256=}" != "$(sha256 "$TEMPLATE") setup=$(sha256 "$SETUP")" ]; then
    die "infra/code2.yaml or infra/setup.sh changed after $cs was planned; run plan again"
  fi
  type=$( [ "$(stack_status)" = REVIEW_IN_PROGRESS ] && echo create || echo update )
  [ "${CODE2_KEEP_ON_FAILURE:-}" != 1 ] || rollback=(--disable-rollback)
  [[ "$desc" == "code2 migrate"* ]] || upload_setup   # a new or restarted instance runs it at boot
  echo "executing $cs"
  aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name "$cs" ${rollback[@]+"${rollback[@]}"}
  if ! aws cloudformation wait "stack-$type-complete" --stack-name "$STACK"; then
    aws cloudformation describe-stack-events --stack-name "$STACK" --max-items 30 \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
    [[ "$desc" == "code2 migrate"* ]] || restore_setup
    die "$STACK: $(stack_status)"
  fi
  echo "$STACK: $(stack_status)"
  if [[ "$desc" == "code2 migrate"* ]]; then echo "now run infra/deploy.sh stack plan again for step 2"; return; fi
  # Settings changes reach a running instance here. A new or restarted one runs setup.sh at boot too; setup.sh
  # takes a lock, so this run waits for that one and then finds little to change.
  [ "$type" = update ] || return 0
  load_outputs
  if [ "$(instance_state)" != running ]; then echo "$INSTANCE is $(instance_state): setup.sh runs when it starts"; return; fi
  # Subshell: ssm_run exits when the instance is not in Systems Manager yet (it then runs setup.sh at boot). Not in
  # an if or ||, which would turn off set -e inside it.
  local rc=0
  set +e; ( set -e; reconfigure ); rc=$?; set -e
  [ "$rc" = 0 ] || warn "setup.sh did not run now; if the instance was restarting it runs at boot (check with infra/deploy.sh logs)"
}

# Runs the user data on the instance: the bootstrap, which fetches setup.sh and runs it (an older stack's user data
# is the whole setup). Services restart only if their setup changed.
reconfigure() {
  echo "running setup.sh on $INSTANCE (no restart; services restart only if their setup changed)"
  ssm_run 't=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")' \
    'curl -fsS -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/user-data > /run/code2-userdata' \
    'bash /run/code2-userdata > /dev/null 2>&1 || { tail -n 30 /var/log/code2-setup.log; exit 1; }' \
    'tail -n 5 /var/log/code2-setup.log'
}

# ---------- instance helpers ----------
load_outputs() {
  local o
  o=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json 2>/dev/null || echo null)
  [ "$o" != null ] || die "$STACK has no outputs (status $(stack_status))"
  out() { jq -r --arg k "$1" '.[] | select(.OutputKey == $k).OutputValue' <<<"$o"; }
  INSTANCE=$(out InstanceId) IP=$(out InstancePrivateIp) EICE=$(out InstanceConnectEndpointId)
  URL=$(out Url) LOGOUT=$(out LogoutUrl) LOG_GROUP=$(out LogGroupName)
}
instance_state() { aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].State.Name' --output text; }

# ssm_run <command...>: runs commands as root on the instance, prints stdout, fails with the command.
ssm_run() {
  local id st=Pending deadline=$((SECONDS + 3700))   # executionTimeout below, plus delivery
  [ "$(instance_state)" = running ] || die "$INSTANCE is $(instance_state)"
  aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
    --query 'InstanceInformationList[0].PingStatus' --output text | grep -q Online || die "$INSTANCE is not online in Systems Manager yet"
  id=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
    --parameters "$(jq -nc '{commands: $ARGS.positional, executionTimeout: ["3600"]}' --args "$@")" \
    --query Command.CommandId --output text) || die "send-command to $INSTANCE failed"
  [ -n "$id" ] || die "send-command to $INSTANCE returned no command id"
  while [[ "$st" =~ ^(Pending|InProgress|Delayed)$ ]]; do
    [ "$SECONDS" -lt "$deadline" ] || die "command $id still $st after $((3700 / 60)) minutes"
    sleep 3
    st=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
  done
  aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" --query StandardOutputContent --output text
  [ "$st" = Success ] || { aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" \
    --query StandardErrorContent --output text >&2; die "command $st"; }
}

# One-off key: EC2 Instance Connect accepts it for 60 seconds, then the tunnel goes through the EICE. The host key
# alias includes the instance id, so a replaced instance does not clash with the old one's key.
ssh_instance() {
  load_outputs
  local key=${CODE2_SSH_KEY:-$HOME/.ssh/id_ed25519}
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -f "$key"
  aws ec2-instance-connect send-ssh-public-key --instance-id "$INSTANCE" --instance-os-user ec2-user \
    --ssh-public-key "file://$key.pub" --query Success --output text >/dev/null
  exec ssh -i "$key" -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$STACK-$INSTANCE" \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-connect-endpoint-id $EICE --private-ip-address $IP --remote-port 22" \
    "ec2-user@$IP" "$@"
}

destroy() {
  local s pool vol ans
  s=$(stack_status)
  [ "$s" != NONE ] || die "no stack $STACK in $AWS_REGION"
  pool=$(physical_id UserPool) vol=$(physical_id DataVolume)
  if [ "${CODE2_YES:-}" != 1 ]; then
    read -rp "delete stack $STACK ($s) in $AWS_REGION, account $caller? type the stack name: " ans
    [ "$ans" = "$STACK" ] || die "not deleted"
  fi
  aws cloudformation delete-stack --stack-name "$STACK"
  if ! aws cloudformation wait stack-delete-complete --stack-name "$STACK"; then
    aws cloudformation describe-stack-events --stack-name "$STACK" --max-items 20 \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
    die "delete did not finish; a CloudFront-VPCOrigins-Service-SG that lingers in the VPC clears after a while: run destroy again"
  fi
  aws s3api delete-object --bucket "$BUCKET" --key "$STACK/setup.sh" --expected-bucket-owner "$caller" >/dev/null 2>&1 || true
  if [ "$(aws s3api list-objects-v2 --bucket "$BUCKET" --expected-bucket-owner "$caller" --max-items 1 \
      --query 'length(Contents || `[]`)' --output text 2>/dev/null)" = 0 ]; then
    aws s3api delete-bucket --bucket "$BUCKET" --expected-bucket-owner "$caller" 2>/dev/null || true
  fi
  echo "$STACK deleted. Left behind on purpose:"
  if [ -n "$pool" ] && [ "$pool" != None ]; then
    echo "- user pool $pool (retained, deletion protection). To remove it:"
    echo "    aws cognito-idp update-user-pool --user-pool-id $pool --deletion-protection INACTIVE"
    echo "    aws cognito-idp delete-user-pool --user-pool-id $pool"
  fi
  if [ -n "$vol" ] && [ "$vol" != None ]; then
    echo "- /home snapshots of $vol (the final one and daily backups); restore with CODE2_RESTORE_SNAPSHOT:"
    aws ec2 describe-snapshots --owner-ids self --filters "Name=volume-id,Values=$vol" \
      --query 'reverse(sort_by(Snapshots,&StartTime))[].[SnapshotId,StartTime,VolumeSize,State]' --output table
  fi
}

case "$1" in
  stack)
    case "${2:-}" in
      plan) plan ;;
      apply) apply ;;
      *) usage ;;
    esac ;;
  status)
    load_outputs
    echo "url:      $URL"
    [ -z "$LOGOUT" ] || echo "logout:   $LOGOUT"
    state=$(instance_state)
    echo "instance: $INSTANCE ($IP) $state"
    # Subshell: ssm_run dies (exits) when the instance is not in Systems Manager yet; status still ends normally.
    if [ "$state" = running ]; then
      ( ssm_run "systemctl is-active code-server oauth2-proxy | paste -sd' '" "df -h /home | tail -1" \
        "readlink -f /usr/local/bin/code-server /usr/local/bin/oauth2-proxy" ) || true
    fi ;;
  logs)
    load_outputs
    [ -n "$LOG_GROUP" ] || die "no log group yet (run stack plan/apply, then reconfigure)"
    follow=(); since=1h
    for a in "${@:2}"; do if [ "$a" = -f ]; then follow=(--follow); else since=$a; fi; done
    aws logs tail "$LOG_GROUP" --since "$since" ${follow[@]+"${follow[@]}"} ;;
  reconfigure) load_outputs; upload_setup; reconfigure ;;
  ssh) shift; ssh_instance "$@" ;;
  ssh-config)
    load_outputs
    key=${CODE2_SSH_KEY:-$HOME/.ssh/id_ed25519}
    cat <<EOF
# push a key first (valid 60 s); regenerate this block if the instance is replaced:
#   aws ec2-instance-connect send-ssh-public-key --region $AWS_REGION --instance-id $INSTANCE --instance-os-user ec2-user --ssh-public-key file://$key.pub
Host $STACK
  HostName $IP
  User ec2-user
  IdentityFile $key
  HostKeyAlias $STACK-$INSTANCE
  ProxyCommand aws ec2-instance-connect open-tunnel --region $AWS_REGION --instance-connect-endpoint-id $EICE --private-ip-address %h --remote-port %p
EOF
    ;;
  shell) load_outputs; aws ssm start-session --target "$INSTANCE" ;;
  stop) load_outputs; aws ec2 stop-instances --instance-ids "$INSTANCE" --query 'StoppingInstances[0].CurrentState.Name' --output text ;;
  start) load_outputs; aws ec2 start-instances --instance-ids "$INSTANCE" --query 'StartingInstances[0].CurrentState.Name' --output text ;;
  destroy) destroy ;;
  *) usage ;;
esac
